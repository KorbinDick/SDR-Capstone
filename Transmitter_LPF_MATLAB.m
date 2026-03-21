%generate 48 tap LPF (Fs=48k, fc=3600 Hz)
clear
clc

%our fs (Hz)
Fs = 48000;

%cutoff (Hz)
fc = 3600;

%taps (coefficient count)
numTaps = 64;     

%kaiser beta (59.97dB stopband attenuation)
%increasing beta makes:
%stopband attenuation better (lower sidelobes), transition band wider (filter gets less sharp)
%reducing beta:
%sharpens the cutoff, but increases ripple / reduces attenuation
beta = 5.65;      

%normalized cutoff for fir1, doesn't take hertz
%MATLAB fir1() needs cutoff normalized to nyquist frequency (Fs/2 = 24 kHz)
Wn = fc / (Fs/2);

%designed linear phase FIR using fir1 with Kaiser window
%filter order is always one less than the number of taps
b = fir1(numTaps-1, Wn, 'low', kaiser(numTaps, beta));

%1 = no feedback, frequency response at 4096 points, fs is 48khz,
[H, f] = freqz(b,1,4096,Fs);
plot(f,20*log10(abs(H))),
grid on
xlabel('Hz')
ylabel('Magnitude (dB)')
title('Frequency Response Of 64 Tap LPF')
xlim([0 10000])


%multiplier 2^31-1
q31_mult = 2147483647;
%array with q31 values
q31 = int64(round(b*q31_mult))


