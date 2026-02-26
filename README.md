# Software Defined Radio Capstone Project / York College of Pennsylvania

ESP32_WROOM-32 based software defined radio project using Pmod I2S2 ADC/DAC, Direct Digital Synthesis (sine LUT and phase accumualtor), Codec2, modular framing bits, I/Q based modulation (FSK SSB) and demodulation (Non-coherent quadrature DDS based matched filters). 

Developed in C++, using Arduino IDE, FreeRTOS and I2S configured.

The project is in development, only one way communication is achieved so far, transmitter (Tx) to receiver (Rx).

The system (Tx and Rx) consists of various different components. The goal of the project is to have over the air communication using a software defined radio. A total BOM will be attached at the end of the project duration. The overall effective data rate of the system is 4800 bits per second. Although Codec2 2400 bits per second mode is used, the data transmission speed is 4800bps (bits/second). Through DDS, mark and space frequencies (9.6kHz and 4.8kHz respectively) are used to represent bits, 9.6kHz for logical '1' and 4.8kHz for logical '0'. 

## Current System Diagram:

<img width="1396" height="530" alt="image" src="https://github.com/user-attachments/assets/cbb22c0b-02b5-4ed9-ba58-4ec6feeac8b6" />

## Data Walkthrough and Formatting:

## How Data Looks at the DAC (Tx):

## Mixing and LOs (FSK SSB Achieved through IQ):

## Modulation (FSK SSB Achieved through IQ):

## Digital Processing on the Receiver Side:




-----------------------------------------------------------------------
## Included Libraries:
https://github.com/sh123/esp32_codec2_arduino/tree/master

https://github.com/pschatzmann/arduino-audio-tools

