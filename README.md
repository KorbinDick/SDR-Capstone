# Software Defined Radio Capstone / York College of Pennsylvania

ESP32_WROOM-32 based software defined radio project using Pmod I2S2 ADC/DAC, Direct Digital Synthesis (sine LUT and phase accumulator), Codec2, modular framing bits, I/Q based modulation (FSK SSB) and demodulation (Non-coherent quadrature DDS based matched filters). 

Developed in C++, using Arduino IDE, FreeRTOS and I2S configured.

The project is in development, only one way communication is achieved so far, transmitter (Tx) to receiver (Rx).

The system (Tx and Rx) consists of various different components. The goal of the project is to have over the air communication using a software defined radio. A total BOM will be attached at the end of the project duration. The overall effective data rate of the system is 4800 bits per second. Although Codec2 2400 bits per second mode is used, the data transmission speed is 4800bps (bits/second). Through DDS, mark and space frequencies (9.6kHz and 4.8kHz respectively) are used to represent bits, 9.6kHz for logical '1' and 4.8kHz for logical '0'. 

## Current System Diagram

<img width="1314" height="590" alt="image" src="https://github.com/user-attachments/assets/c2c48097-4d04-432b-955b-de7bd69e7e9d" />

## Data Walkthrough and Formatting (Tx)

An audio signal is sampled on the Tx side through the use of pulse code modulation (PCM). The Pmod I2S2 ADC/DAC on the Tx side uses a 48kHz sampling rate, with a 24 bit resolution. The ESP32 DMA buffers for I2S store samples in 32 bits of length. The 24 bits of each sample reside in the top three bytes of the four byte long space, resulting in the least significant byte being zero (24 bits of data and 8 bits of LSB padding). The Pmod board is a stereo product, even though it is used in stereo for both the Tx and the Rx, only true stereo is used on the Tx side, specifically when sampling the audio coming into the ADC. 

The Tx code consists of three FreeRTOS tasks, rxTask, codec2Task, and txTask. 

```
    void rxTask(void *pvParameters)
    void codec2Task(void *pvParameters)
    void txTask(void *pvParameters)
```

rxTask data starts from 32 bit words (24 bits of PCM data with 8 bits of LSB padding) sampled at 48kHz, and leaves the rxTask at 16 bits per sample sampled at 8kHz. Codec2 2400 mode expects data in 16 bit PCM format, sampled at 8kHz. The rxTask passes on the Codec2 ready data in a queue to be encoded in codec2Task.

The rxTask in is the beginning of the data flow. PCM values each representing the audio signals amplitude at a certain time are read from I2S ESP32 DMA buffers, truncated to true 24 bit values, averaged between the left and right channels, truncated further to 16 bit PCM values, converting to Q31 format, decimating by applying a 3.6kHz cutoff 64 tap filter in Q31 and dropping all samples besides every 6th sample, a factor of 6 (48:8). Therefore, the data leaving the rxTask is Codec2 2400 mode ready, ready to be encoded into 48 bit frames every 20ms (see Codec2 library).


Reading data from I2S DMA buffers:

```
    size_t bytesNeeded = DMA_TX_RX_SIZE * sizeof(int32_t);
    int32_t inBuf[DMA_TX_RX_SIZE];
    int bytesRead = i2sStream.readBytes((uint8_t*)inBuf, bytesNeeded);
```
Truncating 32 bit words, extracting 24 bits of PCM samples:

```
    int32_t L24 = inBuf[2*f] >> 8;
    int32_t R24 = inBuf[2*f+1] >> 8;
```
Averaging the left and right channels together:

```
    int32_t mono32 = (L24 + R24)/2;
```
Truncating to 16 bit PCM values and then scaling to back to Q31:

```
    int16_t mono16 = (int16_t)(mono32 >> 8);
    int32_t sample_q31 = ((int32_t)mono16) << 16;
```


After the samples are in Q31 format, a 64 tap low pass filter (LPF) is applied through convolution. The filter taps can be found in the fir_64_taps_q31.h file. With a decimation factor of 6, going from 48kHz sampled data to 8kHz sampled data, a 3.6kHz cutoff frequency was designed for the filter to prevent any aliasing.

64 samples are kept in the state_q31 buffer, and after every sixth PCM sample, the LPF is applied to the most recent 64 samples through convolution. The products are scaled down to prevent the risk of overflow and convert back to Q31.

```
    for (int k = 0; k < TAPS; k++)
    int32_t h_k  = fir64_q31[k];      
    int32_t x_nk = state_q31[idx];
    acc64 += ((int64_t)h_k * x_nk) >> 31;
```

Then the Q31 new sample is then scaled down to 16 bits, and sent to the Codec2 through the pcmQueue.

```
    int32_t out32 = (int32_t)(acc64 >> 16);
    int16_t out16 = (int16_t)out32;
    if (xQueueSend(pcmQueue, &out16, pdMS_TO_TICKS(5)) != pdTRUE)
    pcmQueueDrops++;
```

After the rxTask, 16 bit samples which are now sampled at 8kHz are sent to the codec2Task through the pcmQueue. Inside the codec2Task, Codec2 2400bps mode is used, where the expected data input format is 16 bit PCM at 8kHz (20ms of input samples * 8kHz = 160 samples) and the output data format is 48 encoded bits.

Creating the Codec2 object in 2400bps mode.

```
    c2 = codec2_create(CODEC2_MODE_2400);
```

Encoding 160 samples in 48 bit (6 byte) payloads.

```
    codec2_encode(c2, enc, codec_accum);
```

A buffer holds the 48 bits, MSB first, of the encoded data. Framing is then added to the data. Modularity is this project was a goal to reach such that the user can adjust or change parameters or single variables at the top of the code to change things to their liking, without having to change any operations. Framing gets added by taking named variables such as PREMABLE_FLAG and POSTAMBLE_FLAG, and bit masking is used to set the bits in the frame. The frame is comprised of the payload and the framing bits. As of right the time of writing, with a 48 bit payload (2400bps mode), 8 bits of framing (preamble) are used for receover synchronization and detection.

## How Data Looks at the DAC (Tx)

## Modulation (FSK SSB Achieved through IQ)

## Data Walkthrough and Formatting (Rx)

## I2S

## Codec2



-----------------------------------------------------------------------
### Included Libraries
https://github.com/sh123/esp32_codec2_arduino/tree/master

https://github.com/pschatzmann/arduino-audio-tools

