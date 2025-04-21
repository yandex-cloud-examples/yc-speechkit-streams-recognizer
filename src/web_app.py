import os
import json
import base64
import argparse
from bottle import Bottle, request, response, static_file, template
from gevent.pywsgi import WSGIServer
from geventwebsocket.handler import WebSocketHandler
from geventwebsocket.websocket import WebSocket
import wave
import audioop
import grpc
import yandex.cloud.ai.stt.v3.stt_pb2 as stt_pb2
import yandex.cloud.ai.stt.v3.stt_service_pb2_grpc as stt_service_pb2_grpc

app = Bottle()
API_KEY = None

# Serve static files
@app.route('/static/<filepath:path>')
def serve_static(filepath):
    return static_file(filepath, root=os.path.join(os.path.dirname(__file__), 'static'))

# Serve the main page
@app.route('/')
def index():
    template_path = os.path.join(os.path.dirname(__file__), 'templates', 'index.tpl')
    return template(template_path)

# WebSocket endpoint for audio streaming
@app.route('/ws')
def handle_websocket():
    wsock = request.environ.get('wsgi.websocket')
    if not wsock:
        response.status = 400
        return "Expected WebSocket request."
    
    try:
        process_audio_stream(wsock)
    except Exception as e:
        print(f"Error in WebSocket: {str(e)}")
        wsock.send(json.dumps({"error": str(e)}))
    finally:
        wsock.close()

def process_audio_stream(wsock: WebSocket):
    """Process audio data from WebSocket and send recognition results back."""
    # Setup gRPC connection to Yandex STT
    cred = grpc.ssl_channel_credentials()
    channel = grpc.secure_channel('stt.api.cloud.yandex.net:443', cred)
    stub = stt_service_pb2_grpc.RecognizerStub(channel)
    
    # Audio parameters
    sample_rate = 48000  # Default sample rate
    channels = 1
    
    # Variables for real-time streaming
    client_sample_rate = None
    need_resample = False
    target_sample_rate = sample_rate
    resampler_state = None
    
    # Create a queue for audio chunks and a flag for streaming state
    import queue
    import threading
    audio_queue = queue.Queue()
    stream_finished = threading.Event()
    
    # Wait for initial config message
    try:
        config_message = wsock.receive()
        if config_message is None:
            print("WebSocket closed before receiving config")
            return
            
        config = json.loads(config_message)
        print(f"Received config: {config}")
        client_sample_rate = config.get('sampleRate', 48000)
        
        # Determine if resampling is needed
        need_resample = client_sample_rate not in [8000, 16000, 48000]
        target_sample_rate = get_best_target_rate(client_sample_rate) if need_resample else client_sample_rate
        sample_rate = target_sample_rate
        
        print(f"Using sample rate: {sample_rate} Hz")
        
        # Function to generate requests for the gRPC stream
        def request_generator():
            # First message with recognition options
            recognize_options = stt_pb2.StreamingOptions(
                recognition_model=stt_pb2.RecognitionModelOptions(
                    audio_format=stt_pb2.AudioFormatOptions(
                        raw_audio=stt_pb2.RawAudio(
                            audio_encoding=stt_pb2.RawAudio.LINEAR16_PCM,
                            sample_rate_hertz=sample_rate,
                            audio_channel_count=channels
                        )
                    ),
                    text_normalization=stt_pb2.TextNormalizationOptions(
                        text_normalization=stt_pb2.TextNormalizationOptions.TEXT_NORMALIZATION_ENABLED,
                        profanity_filter=True,
                        literature_text=False
                    ),
                    language_restriction=stt_pb2.LanguageRestrictionOptions(
                        restriction_type=stt_pb2.LanguageRestrictionOptions.WHITELIST,
                        language_code=['auto']
                    ),
                    audio_processing_type=stt_pb2.RecognitionModelOptions.REAL_TIME
                ),
                eou_classifier=stt_pb2.EouClassifierOptions(
                    default_classifier=stt_pb2.DefaultEouClassifier(
                        max_pause_between_words_hint_ms=1000
                    )
                )
            )
            
            yield stt_pb2.StreamingRequest(session_options=recognize_options)
            
            # Process audio chunks from the queue
            while not stream_finished.is_set() or not audio_queue.empty():
                try:
                    # Get audio chunk with timeout to check stream_finished periodically
                    chunk = audio_queue.get(timeout=0.1)
                    yield stt_pb2.StreamingRequest(chunk=stt_pb2.AudioChunk(data=chunk))
                    audio_queue.task_done()
                except queue.Empty:
                    continue
        
        # Start the recognition stream in a separate thread
        metadata = [('authorization', f'Api-Key {API_KEY}')]
        
        # Function to process responses from the recognition stream
        def process_responses(responses):
            try:
                for response in responses:
                    event_type = response.WhichOneof('Event')
                    alternatives = None
                    
                    if event_type == 'partial' and len(response.partial.alternatives) > 0:
                        alternatives = [a.text for a in response.partial.alternatives]
                    elif event_type == 'final':
                        alternatives = [a.text for a in response.final.alternatives]
                    elif event_type == 'final_refinement':
                        alternatives = [a.text for a in response.final_refinement.normalized_text.alternatives]
                    
                    print(f"Received response: type={event_type}, alternatives={alternatives}")
                    
                    # Send the result to the client
                    if alternatives is not None:
                        wsock.send(json.dumps({
                            'type': event_type,
                            'alternatives': alternatives
                        }))
            except grpc.RpcError as rpc_error:
                error_message = f"gRPC error: {rpc_error.code()}, details: {rpc_error.details()}"
                print(error_message)
                wsock.send(json.dumps({"error": error_message}))
            except Exception as e:
                error_message = f"Error in recognition stream: {str(e)}"
                print(error_message)
                wsock.send(json.dumps({"error": error_message}))
            finally:
                stream_finished.set()
        
        # Start the recognition stream
        print("Starting recognition stream...")
        responses = stub.RecognizeStreaming(request_generator(), metadata=metadata)
        
        # Start processing responses in a separate thread
        response_thread = threading.Thread(target=process_responses, args=(responses,))
        response_thread.daemon = True
        response_thread.start()
        
        # Process incoming audio data
        while True:
            message = wsock.receive()
            if message is None:
                print("WebSocket connection closed")
                break
                
            try:
                data = json.loads(message)
                print(f"Received message type: {data.get('type')}")
                
                if data.get('type') == 'audio':
                    try:
                        # Decode base64 audio data
                        audio_data = base64.b64decode(data.get('data'))
                        
                        # Resample if needed
                        if need_resample:
                            audio_data, resampler_state = audioop.ratecv(
                                audio_data,
                                2,  # 16-bit audio = 2 bytes per sample
                                channels,
                                client_sample_rate,
                                target_sample_rate,
                                resampler_state
                            )
                        
                        # Add to the queue for processing
                        audio_queue.put(audio_data)
                    except Exception as e:
                        print(f"Error processing audio chunk: {str(e)}")
                        wsock.send(json.dumps({"error": f"Error processing audio: {str(e)}"}))
                
                elif data.get('type') == 'stop':
                    print("Received stop command")
                    break
            except Exception as e:
                print(f"Error parsing message: {str(e)}")
                wsock.send(json.dumps({"error": f"Error parsing message: {str(e)}"}))
                break
        
        # Signal that we're done streaming
        stream_finished.set()
        
        # Wait for the response thread to finish
        if 'response_thread' in locals() and response_thread.is_alive():
            response_thread.join(timeout=5.0)
    except Exception as e:
        print(f"Error in WebSocket processing: {str(e)}")
        wsock.send(json.dumps({"error": f"Error in WebSocket processing: {str(e)}"}))
    finally:
        # Ensure the stream is properly terminated
        if 'stream_finished' in locals():
            stream_finished.set()

def get_best_target_rate(device_rate):
    """Find the closest supported sample rate."""
    supported_rates = [8000, 16000, 48000]
    if device_rate in supported_rates:
        return device_rate
    
    # Find the closest supported rate (preferring higher rates)
    if device_rate < 8000:
        return 8000
    elif device_rate < 16000:
        return 16000
    else:
        return 48000

def main():
    parser = argparse.ArgumentParser(description='Web app for Yandex speech recognition')
    parser.add_argument('--api-key', required=False, help='API key for Yandex STT')
    parser.add_argument('--port', type=int, required=False, help='Port to run the web server on')
    args = parser.parse_args()
    
    global API_KEY
    # Use command line argument if provided, otherwise check environment variable, with a default of None
    API_KEY = args.api_key or os.environ.get('API_KEY')
    
    if not API_KEY:
        print("Error: API key must be provided via --api-key argument or API_KEY environment variable")
        return
    
    # Use command line argument if provided, otherwise check environment variable, with a default of 8080
    port = args.port or int(os.environ.get('PORT', 8080))
    
    # Ensure directories exist
    script_dir = os.path.dirname(os.path.abspath(__file__))
    os.makedirs(os.path.join(script_dir, 'static'), exist_ok=True)
    os.makedirs(os.path.join(script_dir, 'templates'), exist_ok=True)
    
    # Start the web server
    print(f"Starting web server on http://localhost:{port}")
    server = WSGIServer(('0.0.0.0', port), app, handler_class=WebSocketHandler)
    server.serve_forever()

if __name__ == '__main__':
    main()
