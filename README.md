# Software Defined Radio Capstone

ESP32 based software defined radio project using Pmod I2S2 ADC/DAC, Direct Digital Synthesis (sine LUT and phase accumulator), Codec2, modular framing bits, I/Q based modulation (FSK SSB) and demodulation (Non-coherent quadrature DDS based matched filters). 

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

Codec2 instance creation in 2400bps mode.

```
    c2 = codec2_create(CODEC2_MODE_2400);
```

Encoding 160 samples in 48 bit (6 byte) payloads.

```
    codec2_encode(c2, enc, codec_accum);
```

A buffer holds the 48 bits, MSB first, of the encoded data. Framing is then added to the data. Modularity is this project was a goal to reach such that the user can adjust or change parameters or single variables at the top of the code to change things to their liking, without having to change any operations. Framing gets added by taking named variables such as PREMABLE_FLAG and POSTAMBLE_FLAG, and bit masking is used to set the bits in the frame. The frame is comprised of the payload and the framing bits. As of right the time of writing, with a 48 bit payload (2400bps mode), 8 bits of framing (preamble) are used for receover synchronization and detection. The total frame length is 56 bits, 8 + 48. 

Bit masking 8 bits of preamble (0x7E or 01111110) and then the Codec2 payload. MSB first, the preamble and then the payload, where the f rame sizee is 7 bytes. Effectively takes no time to ADD a preamble, transmitting it does take more time.

```
    for (int p = 0; p < PREAMBLE_FLAGS; p++) {
        uint8_t flag = PREAMBLE_FLAG;
            for (int b = 7; b >= 0; b--) {
                uint8_t bit = (flag >> b) & 1;
                frame[bitIndex >> 3] |= (bit << (7 - (bitIndex & 7)));
                bitIndex++;
            }
    }

    for (int i = 0; i < 6; i++) {
        uint8_t x = enc[i];
            for (int b = 7; b >= 0; b--) {
                uint8_t bit = (x >> b) & 1;
                frame[bitIndex >> 3] |= (bit << (7 - (bitIndex & 7)));
                bitIndex++;
            }
    }
```

This frame is then sent to the txTask through the frameQueue.

```
    if (xQueueSend(frameQueue, frame, pushTimeout) != pdTRUE) {
```

The txTask uses the I2S Tx setup, the same sampling rate and bit depth as the Rx side (talking I2S Tx/Rx inside of the Tx side of the system). I2S DMA buffers are written to ultimately with the 24 bit PCM values of the sine tones to be generated, 4.8kHz and 9.6kHz. The data arrives as a 56 bit frame to txTask, but each bit is then mapped to a ceratin one of those freqeuncies as discussed earlier. This is done through DDS, where a phase accumulator is kept and incremented by the phase increment assigned to whichever bit is currently present, and through the use of the accumulator, the sine look up table is indexed for the 24 bit PCM value representing the desired tone.

```
    uint32_t idxI = (phase >> (PHASE_BITS - 12)) & 0xFFF;
    uint32_t idxQ = ((phase + QUARTER_PHASE) >> (PHASE_BITS - 12)) & 0xFFF;

    int32_t sampleI = (int32_t)(sineTable[idxI]) << 8;
    int32_t sampleQ = (int32_t)(sineTable[idxQ]) << 8;
```

After indexing the sine look up table and getting the 24 bit PCM value representing one of the two frequencies, 4.8kHz or 9.6kHz, the 24 PCM value is put in the top most significant bytes in a 32 bit word, with 8 bits of padding and the lower significant byte. The PCM values representing the output frequency is then written back out to I2S DMA buffers, which provide the data to the DAC.

```
outBuf[2*i] = sampleI;
outBuf[2*i+1] = sampleQ;

size_t wrote = i2sStream.write((uint8_t*)outBuf, DMA_TX_RX_SIZE * sizeof(int32_t));
```

The following sections go into more detail for both the Tx and the Rx side.


## I2S

I2S (Inter-IC Sound) is the protocol used to transfer data between the Pmod I2S2 ADC/DAC and the ESP32. The audiotools library (see libraries section) is used for high level control of the ESP32 I2S capablities, such as setting LRCLK, MCLK, BCLK, DMA buffer count, DMA buffer size, sampling rate, and bit resolution. I2S is used on each the Tx side and Rx side, however, the only difference between the two are that Tx uses a sampling rate of 48kHz, Rx uses 96kHz. Both Rx and Tx use RXTX mode, meaning data is carried on two channels, effectively stereo audio. Even though the data is carried on two channels, data is taken from those channels and put on those channels in different ways throughout the system. On the Tx side, an audio signal is sampled at 48kHz, data arriving on both the left and right channels. The Tx code currently averages the two channels together, taking the corresponding left and right sample making up a frame. Another possible implementation is just using one of the incoming channels. You may ask why use RXTX mode on the Tx side then? The purpose for this I2S mode is because the ESP32 data out to the data is also stereo, meaning there can be different data on the two channels, which together make one frame. I/Q FSK signals are generated through DDS (upcoming section) at a 24 bit scale, however, one of the channels (right in this case) has been adjusted to have a 90 degree phase offset relative to the other channel (left channel). 24 bit PCM values representing one of the two frequencies are then written to the I2S DMA buffer to go out to the DAC. By using stereo channels, it is possible to get effective 'baseband' FSK I/Q signals. The ESP32 is acting as the master to the Pmod I2S2 board, generating three control clock signals; LRCLK (Word Select), BCLK, and MCLK.

Tx:
LRCLK (WS): 48kHz (sampling rate)
BCLK: (2 channels) x (24 bit resolution) x (48kHz sampling rate) = 2.304MHz
MCLK: (384) x (48kHz) = 18.432MHz

//add images of clock signals here

Rx:
LRCLK (WS): 96kHz (sampling rate)
BCLK: (2 channels) x (24 bit resolution) x (96kHz sampling rate) = 4.608MHz
MCLK: (384) x (96kHz) = 36.864MHz

//add images of clock signals here

The I2S setup also doubles the MCLK multiplier inherently. The team reached out and discussed with the repository owner and they said it was a bug. It can be worked around in our case due to setting the MCLK multiple as half of the expected value to account for the doubling. It is set has 192, but the library doubles it when apll (audio phase locked loop) is set to true.

https://github.com/pschatzmann/arduino-audio-tools/discussions/2192


```
    config.mclk_multiple = I2S_MCLK_MULTIPLE_192;
```

The I2S configuration is set in I2S_STD_FORMAT, which sets Philips Standard Format, which is commonly used as the most compatible I2S setup. Every LRCLK (WS) cycle, the data has a one bit shift delay.

https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/peripherals/i2s.html

## FreeRTOS

FreeRTOS is used for task/thread allocation and communication. Since the audio transmitted would be in real time, it is needed to have different tasks/threads handling different responsabilites when regarding the data. The ESP32 variant is a dual core microcontrller, each core is single threaded and time slices allocation of the core among tasks/threads. However, having two cores means effective 'parallelism', where one core can handle a thread and the other can handle a separate thread. This use of FreeRTOS comes in handy when much is to be done with the data, such as applying digital filters, I2S reads/writes, and data transmission between threads/tasks. Queues are used of specific length and data type to move data from task to task. 

As stated earlier, the Tx side has three tasks and the Rx side also has the same three tasks. The queues on the Rx and Tx side are effectively inverse of each other, such that the frame queue in Tx is for data going from the codec2Task to the txTask, and for the Rx side it is for going from the rxTask to the codec2Task. The pcmQueue is used in the same way as the frame queue, such that on the Tx side it is for buffering data from the rxTask to the codec2Task, and on the Rx side it is for buffering data from the codec2Task to the txTask.

https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/system/freertos.html

## Codec2 and Framing

Codec2 is used to encode/decode the audio data into payloads small enough to be trasnmit at 4800 bits or symbols per second. Due to being open source and available through the Arduino IDE on the ESP32, Codec2 was chosen to achieve narrow band communication. It has been stated previously, but Codec2 2400bps mode is used to encode data, even though the transmission rate is 4800bps through DDS. If you are familiar with data throughout and channel usage/capacity, you should be aware that this will lead to some idle time and inefficient usage of the channel. This has been taken into consideration and is not technically a limitation. The modularity of the software allows users to add framing bits as they would like, allowing different preamble, postamble, error detection or error correction bits (CRC, etc.).

2400bps mode takes 160 16 bit samples at 8kHz (or every 20ms) on the Tx side and encodes the samples into 48 bit payloads, and on the Rx side the opposite happens, decoding 48 bit payloads to 160 16 bit samples, again every 20ms.

On the Tx side, framing bits are added right after encoding to 48 bit payloads. 0x7E (01111110) is used as the projects preamble. The total frame length is is then 56 bits for this projects finish. 

## Direct Digital Synthesis (Sine Look Up Table and Phase Accumulator)



## Modulation (FSK SSB Achieved through IQ)

## Data Walkthrough and Formatting (Rx)




-----------------------------------------------------------------------
### Included Libraries
https://github.com/sh123/esp32_codec2_arduino/tree/master

https://github.com/pschatzmann/arduino-audio-tools

