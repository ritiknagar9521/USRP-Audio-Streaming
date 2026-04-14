% ==========================================
% BPSK AUDIO TRANSMITTER (WITH PREAMBLE)
% ==========================================
clear; clc;

%% 1. SYSTEM PARAMETERS
centerFreq = 915e6;         % You were warned about 915 MHz.
sps = 8;                    % Samples Per Symbol
symbolRate = 100e3;         % 100,000 baud
sdrSampleRate = symbolRate * sps; % 800 kHz

%% 2. READ, RESAMPLE, AND DIGITIZE AUDIO
disp('1. Processing Audio...');
[audioIn, audioFs] = audioread('sample2.mp3');
audioIn = audioIn(:,1); % Force mono

% Downsample to 8 kHz to survive the USB bottleneck
targetAudioFs = 8000; 
audioResampled = resample(audioIn, targetAudioFs, audioFs);

% Quantize floating point to 8-bit integers (0 to 255)
audioInt = uint8((audioResampled + 1) * 127.5); 
audioBits = int2bit(audioInt, 8); 

%% 3. BUILD THE PACKET (Preamble + Data)
disp('2. Building Packet...');
% 13-bit Barker Code (The "Start Here" marker)
barker = comm.BarkerCode('Length', 13, 'SamplesPerFrame', 13);
preambleBits = (barker() + 1) / 2; % Convert -1/1 to 0/1

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
% Calculate the exact interpolation factor
masterClock = 8e6; % 8 MHz Master Clock
interpFactor = masterClock / sdrSampleRate; % 8,000,000 / 800,000 = 10

tx = comm.SDRuTransmitter('Platform', 'B200', ...
    'SerialNum', '34D8DB8', ...
    'CenterFrequency', centerFreq, ...
    'MasterClockRate', masterClock, ...
    'InterpolationFactor', interpFactor, ...
    'Gain', 15);

disp('Broadcasting... (Sending the same packet 3 times for redundancy)');
frameSize = 4096;

% We transmit the whole file 3 times. 
% SDR receivers often miss the first fraction of a second while the AGC adjusts.
for repeats = 1:3 
    for i = 1:frameSize:(length(txWaveform) - frameSize)
        tx(txWaveform(i:i+frameSize-1));
    end
end

release(tx);
disp('Transmission Complete.');