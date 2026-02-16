# Software Defined Radio Capstone Project / York College of Pennsylvania

ESP32_WROOM-32 based software defined radio project using Pmod I2S2 ADC/DAC, Direct Digital Synthesis (sine LUT and phase accumualtor), Codec2, modular framing bits, I/Q based modulation (FSK SSB) and demodulation (Non-coherent quadrature DDS based matched filters). 

Developed in C++, using Arduino IDE, FreeRTOS and I2S configured.

The project is in development, only one way communication is achieved so far, transmitter (Tx) to receiver (Rx).


-----------------------------------------------------------------------
## Included Libraries:
https://github.com/sh123/esp32_codec2_arduino/tree/master

https://github.com/pschatzmann/arduino-audio-tools

https://github.com/etherkit/Si5351Arduino

