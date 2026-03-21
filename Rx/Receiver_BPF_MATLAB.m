%generate any tap BPF (Fs=96k, fc= 3 kHz to 12kHz)
clear
clc

%frequencies in hertz
Fs = 96000;
f1 = 3000;
f2 = 12000;

%modular taps and kaiser beta
numTaps = 64;
beta = 5.65;

%normalizing pass band frequencies by nyquist frequency
Wn = [f1 f2] / (Fs/2);

%bandpass FIR with whichever taps and kaiser window
b = fir1(numTaps-1, Wn, 'bandpass', kaiser(numTaps,beta));

%frequency response used to plot
[H,f] = freqz(b,1,4096,Fs);

%plotting the frequency response of the bandpass filter
figure
plot(f,20*log10(abs(H)))
grid on
xlabel('frequency (Hz)')
ylabel('magnitude (dB)')
title(sprintf('%d Tap 3–12 kHz Bandpass FIR',numTaps))
xlim([0 20000])

%scaling and adjusting for q31 fixed point
q31_mult = 2147483647;
q31 = int64(round(b*q31_mult));

%filename is the name of the file to be written to, effectively an h file
filename = sprintf('bpf_3k_12k_%dtap.h',numTaps);

%open a 'new' file with filename w
fileID = fopen(filename,'w');

%writing to define the tap count
fprintf(fileID,"#define BPF_TAPS %d\n\n", numTaps);

%writing the start of the tap array
fprintf(fileID,"static const int32_t bpfCoeffs[BPF_TAPS] = {\n");

%writing to open file, making sure the last q31 tap is the last
for i = 1:numTaps
    
    if i < numTaps
        fprintf(fileID,"    %d,\n", q31(i));
    else
        fprintf(fileID,"    %d\n", q31(i));
    end
    
end

fprintf(fileID,"};");

fclose(fileID);