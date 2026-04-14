% ==========================================
% LIVE STREAMING BPSK AUDIO RECEIVER
% ==========================================
clear; clc;

%% 1. SYSTEM PARAMETERS
centerFreq = 915e6;         
sps = 8;                    
symbolRate = 100e3;         
sdrSampleRate = symbolRate * sps;
targetAudioFs = 8000; % Must match Tx audio rate

% Calculate the exact decimation factor
masterClock = 8e6; % 8 MHz Master Clock
decimationFactor = masterClock / sdrSampleRate; % 8,000,000 / 800,000 = 10

%% 2. HARDWARE SETUP
rx = comm.SDRuReceiver('Platform', 'B200', ...
    'SerialNum', '34D8DB8', ...
    'CenterFrequency', centerFreq, ...
    'MasterClockRate', masterClock, ...
    'DecimationFactor', decimationFactor, ...
    'Gain', 40, ... % Keep Rx gain high
    'SamplesPerFrame', 4096);

% We use audioDeviceWriter for continuous, non-blocking live audio
audioPlayer = audioDeviceWriter('SampleRate', targetAudioFs, 'SupportVariableSizeInput', true);

%% 3. THE SYNCHRONIZATION PIPELINE 
agc = comm.AGC('DesiredOutputPower', 1, 'MaxPowerGain', 60);
rxFilter = comm.RaisedCosineReceiveFilter('RolloffFactor', 0.5, ...
    'FilterSpanInSymbols', 10, 'InputSamplesPerSymbol', sps, 'DecimationFactor', 1);
symbolSync = comm.SymbolSynchronizer('TimingErrorDetector', 'Gardner (non-data-aided)', ...
    'SamplesPerSymbol', sps);
carrierSync = comm.CarrierSynchronizer('Modulation', 'BPSK', 'ModulationPhaseOffset', 'Auto');
bpskDemod = comm.BPSKDemodulator('PhaseOffset', 0, 'DecisionMethod', 'Hard decision');

%% 4. PREAMBLE SETUP
barker = comm.BarkerCode('Length', 13, 'SamplesPerFrame', 13);
targetPreamble = (barker() + 1) / 2; 

%% 5. REAL-TIME STATE MACHINE VARIABLES
isLocked = false;       % Starts in State 0 (Hunting)
bitBuffer = [];         % The FIFO holding tank

disp('Receiver started.');
disp('STATE 0: Hunting for preamble... (Audio Muted)');

%% 6. THE LIVE RECEIVE LOOP
while true
    % 1. Pull hardware data
  rxWaveform = double(rx());
    
    % 2. Push through the sync pipeline
    sync1 = agc(rxWaveform);
    sync2 = rxFilter(sync1);
    sync3 = symbolSync(sync2);
    sync4 = carrierSync(sync3);
    
    % 3. Extract raw bits
    bits = bpskDemod(sync4);
    
    % Shove new bits into the holding tank
    bitBuffer = [bitBuffer; bits]; 
    
    % ==========================================
    % STATE 0: HUNTING FOR PREAMBLE
    % ==========================================
    if ~isLocked
        % We need at least enough bits to find the preamble safely
        if length(bitBuffer) > 200 
            % Cross-correlate to find the marker
            correlation = xcorr(bitBuffer * 2 - 1, targetPreamble * 2 - 1);
            [maxVal, maxIdx] = max(correlation);
            
            % If the correlation spike is strong enough, we found it
            if maxVal > 11 % 13 is a perfect match, we allow a tiny bit of noise
                startIdx = maxIdx - length(bitBuffer) + 1;
                
                if startIdx > 0
                    disp(['PREAMBLE LOCKED at index ', num2str(startIdx)]);
                    disp('STATE 1: Streaming Live Audio...');
                    
                    isLocked = true; % Switch the state machine
                    
                    % Throw away everything before the preamble AND the preamble itself
                    bitBuffer = bitBuffer(startIdx + length(targetPreamble) : end);
                else
                    % False alarm or bad math, flush the buffer to save memory
                    bitBuffer = []; 
                end
            else
                % Keep buffer small so it doesn't crash memory while hunting
                bitBuffer = bitBuffer(end-100:end); 
            end
        end
        
    % ==========================================
    % STATE 1: STREAMING AUDIO
    % ==========================================
    else
        % Calculate how many full 8-bit bytes we currently have
        numFullBytes = floor(length(bitBuffer) / 8);
        
        if numFullBytes > 0
            % Extract exactly the bits that form complete bytes
            bitsToProcess = bitBuffer(1 : numFullBytes * 8);
            
            % Keep the leftover remainder bits in the tank for the next loop
            bitBuffer = bitBuffer(numFullBytes * 8 + 1 : end);
            
            % Convert the bits into 8-bit integers
            audioIntRx = bit2int(bitsToProcess, 8);
            
            % Convert the integers back into analog voltage (-1.0 to 1.0)
            audioChunk = (double(audioIntRx) / 127.5) - 1.0;
            
            % Shove the audio into the computer's sound card immediately
            audioPlayer(audioChunk);
        end
    end
end

release(rx);