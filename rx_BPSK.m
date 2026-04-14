% ==========================================
% LIVE STREAMING BPSK AUDIO RECEIVER (32-BIT PN)
% ==========================================
clear; clc;

% Mute dropped sample warnings during noise hunting
warning('off', 'comm:SymbolSynchronizer:DroppedSamples');

%% 1. SYSTEM PARAMETERS
centerFreq = 915e6;         
sps = 8;                    
symbolRate = 100e3;         
sdrSampleRate = symbolRate * sps;
targetAudioFs = 8000; 

masterClock = 8e6; 
decimationFactor = masterClock / sdrSampleRate; 

%% 2. HARDWARE SETUP
rx = comm.SDRuReceiver('Platform', 'B200', ...
    'SerialNum', '34D8DB8', ...
    'CenterFrequency', centerFreq, ...
    'MasterClockRate', masterClock, ...
    'DecimationFactor', decimationFactor, ...
    'Gain', 40, ... 
    'SamplesPerFrame', 4096, ...
    'OutputDataType', 'double'); % FIXED: Forces double precision for AGC

audioPlayer = audioDeviceWriter('SampleRate', targetAudioFs, 'SupportVariableSizeInput', true);

%% 3. THE SYNCHRONIZATION PIPELINE (TUNED FOR REALITY)
agc = comm.AGC('DesiredOutputPower', 1, 'MaxPowerGain', 60);

% FIXED: Decimate down to 2 SPS so the Gardner loop doesn't choke on noise
rxFilter = comm.RaisedCosineReceiveFilter('RolloffFactor', 0.5, ...
    'FilterSpanInSymbols', 10, 'InputSamplesPerSymbol', sps, 'DecimationFactor', 4);

% FIXED: SamplesPerSymbol = 2, added Loop Bandwidth to survive drift
symbolSync = comm.SymbolSynchronizer('TimingErrorDetector', 'Gardner (non-data-aided)', ...
    'SamplesPerSymbol', 2, 'NormalizedLoopBandwidth', 0.01);

% FIXED: Added Loop Bandwidth to track frequency mismatch
carrierSync = comm.CarrierSynchronizer('Modulation', 'BPSK', ...
    'ModulationPhaseOffset', 'Auto', 'NormalizedLoopBandwidth', 0.01);

bpskDemod = comm.BPSKDemodulator('PhaseOffset', 0, 'DecisionMethod', 'Hard decision');

%% 4. PREAMBLE SETUP
% Match the 32-bit PN sequence from the transmitter
pnGen = comm.PNSequence('Polynomial', 'z^5 + z^2 + 1', ...
    'SamplesPerFrame', 32, 'InitialConditions', [0 0 0 0 1]);
targetPreamble = pnGen(); 

%% 5. REAL-TIME STATE MACHINE VARIABLES
isLocked = false;       
bitBuffer = [];         

disp('Receiver started.');
disp('STATE 0: Hunting for 32-bit preamble... (Audio Muted)');

%% 6. THE LIVE RECEIVE LOOP
while true
    % 1. Pull hardware data
    rxWaveform = double(rx());
    
    % FIXED: Destroy the hardware DC offset before it ruins the math
    rxWaveform = rxWaveform - mean(rxWaveform);
    
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
        if length(bitBuffer) > 200 
            correlation = xcorr(bitBuffer * 2 - 1, targetPreamble * 2 - 1);
            [maxVal, maxIdx] = max(correlation);
            
            % Require a score of 30 out of 32 (Allows 1 bit error over the air)
            if maxVal >= 30 
                startIdx = maxIdx - length(bitBuffer) + 1;
                
                if startIdx > 0
                    disp(['PREAMBLE LOCKED! Score: ', num2str(maxVal), ' at index ', num2str(startIdx)]);
                    disp('STATE 1: Streaming Live Audio...');
                    
                    isLocked = true; 
                    bitBuffer = bitBuffer(startIdx + length(targetPreamble) : end);
                else
                    bitBuffer = []; 
                end
            else
                % Cap the buffer size to prevent memory crashes
                bitBuffer = bitBuffer(end-100:end); 
            end
        end
        
    % ==========================================
    % STATE 1: STREAMING AUDIO
    % ==========================================
    else
        numFullBytes = floor(length(bitBuffer) / 8);
        
        if numFullBytes > 0
            bitsToProcess = bitBuffer(1 : numFullBytes * 8);
            bitBuffer = bitBuffer(numFullBytes * 8 + 1 : end);
            
            % FIXED: Removed legacy bit2int. Replaced with bi2de.
            bitsMatrix = reshape(bitsToProcess, 8, [])';
            audioIntRx = bi2de(bitsMatrix, 'left-msb');
            
            audioChunk = (double(audioIntRx) / 127.5) - 1.0;
            audioPlayer(audioChunk);
        end
    end
end

release(rx);
