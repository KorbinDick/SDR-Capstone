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
* LRCLK (WS): 48kHz (sampling rate)
  ![Tx_LRCLK](https://github.com/user-attachments/assets/89dff21c-5d36-488b-8531-ca4fc47429db)
* BCLK: (2 channels) x (24 bit resolution) x (48kHz sampling rate) = 2.304MHz
  ![Tx_BCLK](https://github.com/user-attachments/assets/efc30442-fa88-4d43-8a7c-774ecbef1dc5)
* MCLK: (384) x (48kHz) = 18.432MHz
  ![Tx_MCLK](https://github.com/user-attachments/assets/346d4ede-ffda-41e7-9373-0862f808b034)




Rx:
* LRCLK (WS): 96kHz (sampling rate)
  ![Rx_LRCLK](https://github.com/user-attachments/assets/a9e908dc-cd20-4249-aea4-4744d87e6fab)
* BCLK: (2 channels) x (24 bit resolution) x (96kHz sampling rate) = 4.608MHz
  ![Rx_BCLK](https://github.com/user-attachments/assets/8a20cd3d-3941-424c-80db-242b9f13f0ba)
* MCLK: (384) x (96kHz) = 36.864MHz
  ![Rx_MCLK](https://github.com/user-attachments/assets/c567068e-e79a-4108-a872-76ac21ff4ef6)


The I2S setup (library) also doubles the MCLK multiplier inherently. The team reached out and discussed with the repository owner and they said it was a bug. It can be worked around in our case due to setting the MCLK multiple as half of the expected value to account for the doubling. It is set has 192, but the library doubles it when apll (audio phase locked loop) is set to true.

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

## Direct Digital Synthesis / Numerically Controlled Oscillators (Sine Look Up Table and Phase Accumulator)

One of the main parts of both Tx and Rx sides are the DDS setups. Using a sine look up table and phase accumulator along with synthesizing through DACs, the system would not be possible without it.

There have been many iterations in terms of DDS throughout the process of this project. Primarily the change in sineLUT as the previous iterations (256, 1024 indexes) provided sub-optimal performance when it came to trying to achieve coherent FSK generation.

DDS is used on both the Rx and Tx sides. On the Tx side, as previoudly stated, for generating the intermediate frequencies (4.8kHz and 9.6kHz) based on the digital audio bitstream (payloads) and framing after the codec2Task. On the Rx side, it is used as the digital non-coherent frequency detection mechanism.

On the Rx side, samples (after having a bandpass filter applied to them) get mutliplied with the digital LOs (DDS based) in time. This results in a lower and a higher frequency component as the products of the multiplication. If the incoming samples frequency is that of the "matched filter" digital LO, there is a DC component and a higher frequency term, essentially. After accumulating samples, the high frequency term cancels, effectively oscillating around zero, and the DC term adds over accumulation. This is the process which allows the determination of frequency in the incoming signal.

https://www.digikey.com/en/articles/the-basics-of-direct-digital-synthesizers-ddss#:~:text=The%20phase%20accumulator,the%20accumulator%20has%2016%20states

https://www.analog.com/media/en/training-seminars/tutorials/mt-085.pdf


## Modulation (FSK SSB Achieved through IQ)

As for the FSK SSB modulation type that was chosen, there is use of both digital and analog types of "modulation". It has already been covered how the ESP32 maps bit streams, 56 bit frames, to DDS generated frequencies. However, due to the limiations of the Pmod I2S2 DAC, the DDS generated frequencies are bounded by the sampling rate. The max sampling rate of the Pmod board is limited to in the kHz range, so generating frequencies at say 102.9MHz is not possible. As the solution to this issue, frequency conversion is used through analog carrier wave modulation. The FSK tones are mixed uo in frequency with a 102.9MHz phase locked VCO generated carrier wave, and then down converted at the Rx side to get back the FSK IF (intermediate frequency) signal, which then is mapped back to Codec2 frames. 

https://digilent.com/reference/pmod/pmodi2s2/reference-manual?redirect=1

Through analog carrier wave modulation, two frequency components (theoretically) are constructed at the output of a mixer. The sum and the difference are the primary (strongest/hottest) signals out of the mixing process, such as the carrier wave with the FSK tones frequencies added to it and the carrier wave with the FSK tones frequencies subtracted from it, in terms of frequency.

With a 102.9MHz carrier wave and an IF (FSK tones) in the kHz range (4.8kHz/9.6kHz), the separation of the two generated frequency components (sidebands) are effectively kHz apart (9.6kHz apart between each +- 4.8kHz frequency and 19.8kHz between the 9.6kHz frequencies). This can add issues with detection and channel usage as double the bandwidth is used, as only one copy or sideband is required for decoding. The information is effectively copied.

To combat this, single sideband suppression is used. This is achieved by generating one of the DDS FSK tones on one of the output channels of the DAC 90 degrees out of phase with the other channel. For the current implementation, LSB (lower sideband) is used. The left channel output of the DAC is usd for the in-phase (0 degrees) FSK signal and the right channel is used as the quadrature path (90 degrees out of phase) in relation to the left channel. The quadrature path is generated as 90 degrees leading the in-phase path.

The ADF4360 is used on both Rx and Tx sides for the carrier wave generation. On the Tx side, quadrature is also needed between carrier wave signals as well to achieve sideband suppression* (used for this project). This means the carrier wave on the Tx side has to be split into an in-phase and a quadrature signal, in order to get the suppression. A hybrid coupler is used to split the LO (local oscillator) signal from the ADF4360 into a +90 degrees signal (in relation to the other carrier wave path) and a 0 degrees signal. The quadrature (+90) signal from the LO is then mixed with the quadrature channel FSK tones and the in-phase LO path is mixed through a separate mixer with the in-phase FSK channel.

Those two upconverted signals are then added together through an RF combiner. The output of the RF combiner results in the upper sideband being suppressed in strength, making it easier to decode at the receiver end, and limiting the signals transmitted over the air.

https://www.dsprelated.com/freebooks/filters/Trigonometric_Identities.html
https://www.site2241.net/august2025.htm
https://blog.minicircuits.com/iq-mixers-image-reject-down-conversion-single-sideband-ssb-up-conversion/

## Data Walkthrough and Formatting (Rx)




-----------------------------------------------------------------------
## Documents/Sources:

Libraries: [Codec2](https://github.com/sh123/esp32_codec2_arduino/tree/master), [Audio Tools](https://github.com/pschatzmann/arduino-audio-tools)

ESP32 (microcontroller): [WROOM-32 Datasheet](https://documentation.espressif.com/esp32-wroom-32_datasheet_en.pdf), [ESP32 Datasheet](https://documentation.espressif.com/esp32_datasheet_en.pdf), [ESP32 Technical Datasheet](https://documentation.espressif.com/esp32_technical_reference_manual_en.pdf), [ESP32 Pinout](https://myhomethings.eu/en/esp32-pinout-which-pin-is-for-what/)

Pmod I2S2 (DAC/ADC): [Pmod I2S2 Website](https://digilent.com/shop/pmod-i2s2-stereo-audio-input-and-output/?srsltid=AfmBOooTMOfltlEenbGjUNlqvgo0MDkxhJpaJEM0rwyzwNJoJmLi9a2T), [Reference Manual](https://digilent.com/reference/pmod/pmodi2s2/reference-manual?redirect=1), [Schematic](https://digilent.com/reference/_media/reference/pmod/pmodi2s2/pmodi2s2_sch.pdf), [A/D](https://www.cirrus.com/products/cs5343-44), [D/A](https://www.cirrus.com/products/cs4344-45-48)

SBL-1+ (mixer): [SBL-1+ Datasheet](https://www.minicircuits.com/pdfs/SBL-1+.pdf)

ADF4360-9 (PLL VCO): [ADF4360-9 Eval Board](https://www.analog.com/media/en/technical-documentation/user-guides/ug-106.pdf), [ADF4360-9](https://www.analog.com/media/en/technical-documentation/data-sheets/ADF4360-9.pdf)

OPA347/LM386 (baseband operational amplifiers): [OPA347](https://www.ti.com/lit/ds/symlink/opa347.pdf?ts=1767456436820&ref_url=https%253A%252F%252Fwww.ti.com%252Fproduct%252FOPA347), [LM386](https://www.circuits-diy.com/acoustic-audio-amplifier-circuit-using-lm386/)

Codec2 (speech encoder/decoder): [Codec2](https://www.rowetel.com/wordpress/?page_id=452)

Direct Digital Synthesis and Numerically Controlled Oscillators (DDS/NCO): [ADI](https://www.analog.com/media/en/training-seminars/tutorials/mt-085.pdf), [Digikey](https://www.digikey.com/en/articles/the-basics-of-direct-digital-synthesizers-ddss), [DAC Performance](https://www.analog.com/media/en/training-seminars/design-handbooks/Technical-Tutorial-DDS/Section4.pdf), [ADI Forum](https://www.analog.com/en/resources/analog-dialogue/articles/all-about-direct-digital-synthesis.html)

FreeRTOS: [Espressif FreeRTOS](https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/system/freertos.html), [FreeRTOS Examples](https://randomnerdtutorials.com/esp32-freertos-queues-inter-task-arduino/)

I2S: [I2S](https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/peripherals/i2s.html)

Data Formatting: [Clamping](https://stackoverflow.com/questions/66538439/best-practice-for-in-place-clamping-clipping-a-number), [Normalization](https://people.revoledu.com/kardi/tutorial/Similarity/Normalization.html), [DataTypes](https://en.cppreference.com/w/cpp/types/integer.html), [Q31](https://onlinedocs.microchip.com/oxy/GUID-70ACD6B0-A33F-4653-B192-8465EAD1FD98-en-US-11/GUID-889092D2-E1E4-4491-ABDB-47CEEBA41E1D.html)

Decimation/Interpolation: [Decimation/Interpolation](https://web.ece.ucsb.edu/Faculty/Rabiner/ece259/Reprints/087_optimum%20fir%20digital%20filters.pdf), [Linear Interpolation](https://michaelkrzyzaniak.com/AudioSynthesis/2_Audio_Synthesis/8_Interpolation/1_Linear_Interpolation/)

SSB: [Trigonometric Identities](https://www.dsprelated.com/freebooks/filters/Complex_Trigonometric_Identities.html), [GNU Radio](https://www.site2241.net/august2025.htm), [Intro to SSB](https://www.eeworldonline.com/introduction-iq-signal/), [Mini-Circuits IQ Mixers](https://blog.minicircuits.com/iq-mixers-image-reject-down-conversion-single-sideband-ssb-up-conversion/), [Phasing Method](https://www.allaboutcircuits.com/technical-articles/the-phasing-method-and-hilbert-transforms-for-single-sideband-modulation/)

FSK Demod: [FSK Demod PDF](https://inatel.br/docentes/documents/dayan/Publications/77.pdf), [FSK Demod Source](https://mistic-lab.github.io/ece-communications-labs/ece450/lab3/theory), [Goertzel Algorithm](https://wirelesspi.com/goertzel-algorithm-evaluating-dft-without-dft/)

