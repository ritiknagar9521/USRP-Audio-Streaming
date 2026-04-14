% ==========================================
% BPSK AUDIO TRANSMITTER (32-BIT PN SEQUENCE)
% ==========================================
clear; clc;

%% 1. SYSTEM PARAMETERS
centerFreq = 915e6;         
sps = 8;                    
symbolRate = 100e3;         
sdrSampleRate = symbolRate * sps; 

%% 2. READ, RESAMPLE, AND DIGITIZE AUDIO
disp('1. Processing Audio...');
[audioIn, audioFs] = audioread('sample2.mp3');
audioIn = audioIn(:,1); % Force mono
targetAudioFs = 8000; 
audioResampled = resample(audioIn, targetAudioFs, audioFs);

% Quantize to 8-bit integers (0 to 255)
audioInt = uint8((audioResampled + 1) * 127.5); 
% FIXED: Replaced legacy int2bit with modern de2bi
audioBits = de2bi(audioInt, 8, 'left-msb')'; 
audioBits = audioBits(:);

%% 3. BUILD THE PACKET (32-Bit Preamble + Data)
disp('2. Building Packet...');
% 32-bit PN Sequence Generator (LFSR)
pnGen = comm.PNSequence('Polynomial', 'z^5 + z^2 + 1', ...
    'SamplesPerFrame', 32, 'InitialConditions', [0 0 0 0 1]);
preambleBits = pnGen(); 

% Combine Preamble and Audio into one continuous stream
txBitStream = [preambleBits; audioBits];

%% 4. DIGITAL MODULATION & PULSE SHAPING
bpskMod = comm.BPSKModulator('PhaseOffset', 0);
txFilter = comm.RaisedCosineTransmitFilter( ...
    'RolloffFactor', 0.5, ...
    'FilterSpanInSymbols', 10, ...
    'OutputSamplesPerSymbol', sps);

allSymbols = bpskMod(txBitStream);
txWaveform = txFilter(allSymbols);

%% 5. SDR TRANSMISSION
disp('3. Initializing USRP and Transmitting...');
masterClock = 8e6; 
interpFactor = masterClock / sdrSampleRate; 

tx = comm.SDRuTransmitter('Platform', 'B200', ...
    'SerialNum', '34D8DB8', ...
    'CenterFrequency', centerFreq, ...
    'MasterClockRate', masterClock, ...
    'InterpolationFactor', interpFactor, ...
    'Gain', 25); % Boosted slightly for real-world reliability

disp('Broadcasting continuously... Press Ctrl+C to stop.');
frameSize = 4096;

% FIXED: Real receivers need continuous transmission to lock
while true 
    for i = 1:frameSize:(length(txWaveform) - frameSize)
        tx(txWaveform(i:i+frameSize-1));
    end
end
