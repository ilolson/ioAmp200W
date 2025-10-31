# ioAmp200W

Small but powerful USB-C powered two channel speaker amplifier.

# Summary

Integrating the MA5332MS from infineon, a super efficient and compact 2 channel class D amplifier. With a TLV320AIC3256 mini DSP, a low power and compact DSP for consumer audio applications that will allow for tight integration. TPS26750 to control USB PD 3.1 EPR power supplies for up to 240W of DC power. An easy to use RP2350 microcontroller for high level control of the system, and hopefully digital audio in at 24bit/96khz.

The goal is to design a compact and efficient circuit board that can supply a wide range of power to the class D amplifier through USB-C Power Delivery. It will include line in and out for easy audio amplification. Including a quality and easy to use DSP such as the TLV320AIC3256 mini DSP should allow us to explore signal processing techniques to achieve optimal results at different power supply voltages, and different speaker setups. Digital audio in over USB-C should be possible in the future with the RP2350 and the DSP. For fun we can drive a HUB75 matrix panel in real time using existing optimized libraries with our signal.

# Power Supply

The USB PD 3.1 EPR can supply a maximum of 48V@5A for 240 watts DC. Even lower settings such as 20V/3A is a common laptop charging standard and many people already own USB-C bricks that can supply this which should be enough for some decent audio output, it also won't damage anything so it will be a safe default. The highest easily available is 28V@5A for 140W DC. 48V@5A is hard to find and expensive although I do plan on testing it on the first revision. 

# Major Circuits

-RP2350 microcontroller

-TI TPS26750 PD 3.1 EPR controller and power management system

-MA5332MS class D amplifier (up to 100W/Ch without heatsink)

-TLV3256AIC3204 low power consumer audio codec DSP, digital input from RP2350 and analog line in


# Highlights

-USB-C digital audio in (24 bit/96kHz)

-Program/Serial connectivity available while streaming audio over USB for easy real time DSP control

-Line In

-HUB75 interface (for driving LED matrix panels)

-High quality audio amplification at a manageable cost for DIY setups

-Wide range of easily available power supplies

# Status

-Initial schematic design

-Compilable firmware, serial and digital audio in working

-Auto install toolchain and compile scripts

