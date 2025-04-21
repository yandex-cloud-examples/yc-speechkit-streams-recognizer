<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SpeechKit Streaming Recognition</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            max-width: 800px;
            margin: 0 auto;
            padding: 20px;
        }
        .container {
            display: flex;
            flex-direction: column;
            gap: 20px;
        }
        .controls {
            display: flex;
            gap: 10px;
        }
        button {
            padding: 10px 20px;
            font-size: 16px;
            cursor: pointer;
            min-width: 180px;
            text-align: center;
        }
        #startButton {
            background-color: #4CAF50;
            color: white;
            border: none;
        }
        #stopButton {
            background-color: #f44336;
            color: white;
            border: none;
            display: none;
        }
        .status {
            font-style: italic;
            color: #666;
            margin-bottom: 20px;
        }
        .results-container {
            display: flex;
            flex-direction: column; /* Normal column order */
            gap: 20px;
        }
        .final-results {
            min-height: 100px;
            padding: 15px;
            font-size: 24px; /* Match partial results font size */
            background-color: transparent; /* Remove background */
            border: none; /* Remove any borders */
            text-transform: lowercase; /* Keep lowercase conversion */
        }
        .partial-results {
            min-height: 120px;
            padding: 15px;
            background-color: transparent; /* Keep transparent background */
            border: none; /* Keep no borders */
            font-size: 24px; /* Keep larger font */
            text-transform: lowercase; /* Keep lowercase conversion */
            color: #8B0000; /* Dark red color to emphasize importance */
            overflow: hidden; /* Prevent overflow */
        }
        .partial-result {
            color: #8B0000; /* Dark red color for better visibility */
            font-style: normal; /* Keep normal font style */
        }
        .final-result {
            color: #000;
            margin-bottom: 15px;
            display: flex;
            align-items: flex-start;
        }

        .timestamp {
            min-width: 80px;
            color: #666;
            margin-right: 10px;
            font-size: 16px; /* Slightly smaller than the text */
        }
        .session-separator {
            border-top: 1px dashed #999;
            margin: 20px 0;
            padding-top: 10px;
            color: #666;
            font-style: italic;
            font-size: 14px;
        }
        .download-btn {
            background-color: #2196F3;
            color: white;
            border: none;
            display: none;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>SpeechKit Streaming Recognition</h1>
        
        <div class="controls">
            <button id="startButton">Начать запись</button>
            <button id="stopButton">Остановить запись</button>
            <button id="downloadButton" class="download-btn">Скачать текст</button>
        </div>
        
        <div class="status" id="status">Готов к записи</div>
        
        <div class="results-container">
            <div class="partial-results" id="partialResults">
                <p></p>
            </div>
            
            <div class="final-results" id="finalResults">
                <p></p>
            </div>
        </div>
    </div>

    <script>
        let websocket = null;
        let mediaRecorder = null;
        let audioContext = null;
        let audioStream = null;
        
        const startButton = document.getElementById('startButton');
        const stopButton = document.getElementById('stopButton');
        const downloadButton = document.getElementById('downloadButton');
        const statusElement = document.getElementById('status');
        const finalResultsElement = document.getElementById('finalResults');
        const partialResultsElement = document.getElementById('partialResults');
        
        startButton.addEventListener('click', startRecording);
        stopButton.addEventListener('click', stopRecording);
        downloadButton.addEventListener('click', downloadTranscription);
        
        async function startRecording() {
            try {
                // Request microphone access
                audioStream = await navigator.mediaDevices.getUserMedia({ audio: true });
                
                // Create audio context
                audioContext = new (window.AudioContext || window.webkitAudioContext)();
                const sampleRate = audioContext.sampleRate;
                
                // Setup WebSocket connection
                const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
                websocket = new WebSocket(`${protocol}//${window.location.host}/ws`);
                
                websocket.onopen = () => {
                    // Send initial configuration
                    websocket.send(JSON.stringify({
                        type: 'config',
                        sampleRate: sampleRate
                    }));
                    
                    // Setup audio processing
                    const audioInput = audioContext.createMediaStreamSource(audioStream);
                    const scriptProcessor = audioContext.createScriptProcessor(4096, 1, 1);
                    
                    scriptProcessor.onaudioprocess = (e) => {
                        if (websocket.readyState === WebSocket.OPEN) {
                            const inputData = e.inputBuffer.getChannelData(0);
                            
                            // Convert float32 to int16
                            const pcmData = new Int16Array(inputData.length);
                            for (let i = 0; i < inputData.length; i++) {
                                pcmData[i] = Math.max(-32768, Math.min(32767, Math.round(inputData[i] * 32767)));
                            }
                            
                            try {
                                // Send audio data as base64
                                const base64Data = arrayBufferToBase64(pcmData.buffer);
                                const message = JSON.stringify({
                                    type: 'audio',
                                    data: base64Data
                                });
                        
                                if (websocket.readyState === WebSocket.OPEN) {
                                    websocket.send(message);
                                }
                            } catch (error) {
                                console.error("Error sending audio data:", error);
                                statusElement.textContent = `Ошибка отправки аудио: ${error.message}`;
                            }
                        }
                    };
                    
                    audioInput.connect(scriptProcessor);
                    scriptProcessor.connect(audioContext.destination);
                    
                    // Update UI
                    startButton.style.display = 'none';
                    stopButton.style.display = 'block';
                    statusElement.textContent = 'Запись...';
                    
                    // Add a session separator if there are already results
                    if (!finalResultsElement.querySelector('p') && finalResultsElement.children.length > 0) {
                        // Create timestamp for the separator
                        const now = new Date();
                        const formattedDate = now.toLocaleString('ru-RU');
                        
                        // Add separator
                        const separator = document.createElement('div');
                        separator.className = 'session-separator';
                        separator.textContent = `Новая сессия записи (${formattedDate})`;
                        finalResultsElement.appendChild(separator);
                    } else if (finalResultsElement.querySelector('p')) {
                        // If this is the first recording, just clear the placeholder
                        finalResultsElement.innerHTML = '';
                    }
                    
                    // Always clear partial results
                    partialResultsElement.innerHTML = '<p></p>';
                };
                
                // Store the current final result ID to handle refinements
                let currentFinalId = null;
                
                websocket.onmessage = (event) => {
                    try {
                        const data = JSON.parse(event.data);
                
                        if (data.error) {
                            console.error("Server error:", data.error);
                            
                            // Check if this is a gRPC RST_STREAM error, which we can ignore
                            if (data.error.includes("RST_STREAM") || data.error.includes("StatusCode.INTERNAL")) {
                                console.log("Detected recoverable gRPC error, continuing recognition");
                                statusElement.textContent = 'Распознавание продолжается...';
                                
                                // Ensure the UI shows we're still recording
                                startButton.style.display = 'none';
                                stopButton.style.display = 'block';
                                
                                return;
                            }
                            
                            // For other errors, show the error and stop recording
                            statusElement.textContent = `Ошибка: ${data.error}`;
                            stopRecordingCleanup();
                            return;
                        }
                
                        if (data.alternatives && data.alternatives.length > 0) {
                            // Update the results based on the type of response
                            if (data.type === 'partial') {
                                // For partial results, update the partial results container
                                partialResultsElement.innerHTML = `<p class="partial-result">${data.alternatives[0]}</p>`;
                                statusElement.textContent = 'Распознавание...';
                            } else if (data.type === 'final') {
                                // Skip empty results
                                if (!data.alternatives[0] || data.alternatives[0].trim() === '') {
                                    return;
                                }
                                
                                // For final results, add to the final results container
                                currentFinalId = Date.now(); // Generate a unique ID for this final result
                                
                                // Create timestamp with seconds
                                const now = new Date();
                                const hours = now.getHours().toString().padStart(2, '0');
                                const minutes = now.getMinutes().toString().padStart(2, '0');
                                const seconds = now.getSeconds().toString().padStart(2, '0');
                                const timestamp = `${hours}:${minutes}:${seconds}`;
                                
                                const finalHtml = `<div id="final-${currentFinalId}" class="final-result">
                                    <span class="timestamp">${timestamp}</span>
                                    <span class="text">${data.alternatives[0]}</span>
                                </div>`;
                                
                                // Always append to existing results
                                if (finalResultsElement.querySelector('p')) {
                                    // If there's still a placeholder paragraph, replace it
                                    finalResultsElement.innerHTML = finalHtml;
                                } else {
                                    // Otherwise append to existing results
                                    finalResultsElement.insertAdjacentHTML('beforeend', finalHtml);
                                }
                                
                                // Show download button when we have results
                                downloadButton.style.display = 'block';
                                
                                // Clear the partial results
                                partialResultsElement.innerHTML = '<p></p>';
                                statusElement.textContent = 'Распознавание завершено';
                            } else if (data.type === 'final_refinement' && currentFinalId) {
                                // Skip empty refinements
                                if (!data.alternatives[0] || data.alternatives[0].trim() === '') {
                                    return;
                                }
                                
                                // For refinements, update the last final result
                                const finalElement = document.getElementById(`final-${currentFinalId}`);
                                if (finalElement) {
                                    const textElement = finalElement.querySelector('.text');
                                    if (textElement) {
                                        textElement.textContent = data.alternatives[0];
                                    } else {
                                        // Fallback if the structure is different
                                        finalElement.textContent = data.alternatives[0];
                                    }
                                }
                            }
                        }
                    } catch (error) {
                        console.error("Error processing message:", error);
                        statusElement.textContent = `Ошибка обработки сообщения: ${error.message}`;
                    }
                };
                
                websocket.onerror = (error) => {
                    console.error('WebSocket error:', error);
                    statusElement.textContent = 'Ошибка соединения';
                };
                
                websocket.onclose = (event) => {
                    console.log("WebSocket closed with code:", event.code);
                    
                    // Check if we're still recording (audioStream exists)
                    if (audioStream) {
                        // If we still have an active audio stream, we should keep the recording UI state
                        startButton.style.display = 'none';
                        stopButton.style.display = 'block';
                        statusElement.textContent = 'Распознавание продолжается...';
                    } else {
                        // Only reset UI if we're actually stopping the recording
                        startButton.style.display = 'block';
                        stopButton.style.display = 'none';
                        statusElement.textContent = 'Запись остановлена';
                    }
                };
                
            } catch (error) {
                console.error('Error starting recording:', error);
                statusElement.textContent = `Ошибка: ${error.message}`;
            }
        }
        
        function stopRecording() {
            console.log("User initiated stop recording");
            
            if (websocket && websocket.readyState === WebSocket.OPEN) {
                websocket.send(JSON.stringify({ type: 'stop' }));
                // Don't close the websocket here - let the server close it
            }
            
            // Always clean up when the user explicitly stops recording
            stopRecordingCleanup();
        }
        
        function stopRecordingCleanup() {
            console.log("Explicitly stopping recording and cleaning up");
            
            // Stop all audio tracks
            if (audioStream) {
                audioStream.getTracks().forEach(track => track.stop());
                audioStream = null;
            }
            
            // Close audio context
            if (audioContext) {
                audioContext.close().catch(console.error);
                audioContext = null;
            }
            
            // Update UI
            startButton.style.display = 'block';
            stopButton.style.display = 'none';
            statusElement.textContent = 'Запись остановлена';
        }
        
        function downloadTranscription() {
            // Get all final results
            const finalResults = finalResultsElement.querySelectorAll('.final-result, .session-separator');
            if (finalResults.length === 0) {
                alert('Нет текста для скачивания');
                return;
            }
            
            // Combine all results into a single text
            let text = '';
            finalResults.forEach(result => {
                if (result.classList.contains('session-separator')) {
                    // Add session separator to the text
                    text += `\n--- ${result.textContent} ---\n\n`;
                } else {
                    // Process normal result
                    const timestamp = result.querySelector('.timestamp')?.textContent || '';
                    const content = result.querySelector('.text')?.textContent || result.textContent;
                    
                    // Add timestamp and content
                    text += `[${timestamp}] ${content}\n\n`;
                }
            });
            
            // Create a blob and download link
            const blob = new Blob([text], { type: 'text/plain' });
            const url = URL.createObjectURL(blob);
            
            // Create a temporary link and trigger download
            const a = document.createElement('a');
            a.href = url;
            a.download = 'transcription_' + new Date().toISOString().slice(0, 19).replace(/:/g, '-') + '.txt';
            document.body.appendChild(a);
            a.click();
            
            // Clean up
            setTimeout(() => {
                document.body.removeChild(a);
                URL.revokeObjectURL(url);
            }, 100);
        }
        
        // Helper function to convert ArrayBuffer to base64
        function arrayBufferToBase64(buffer) {
            const bytes = new Uint8Array(buffer);
            let binary = '';
            for (let i = 0; i < bytes.byteLength; i++) {
                binary += String.fromCharCode(bytes[i]);
            }
            return window.btoa(binary);
        }
    </script>
</body>
</html>
