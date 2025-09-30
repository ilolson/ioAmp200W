# ioAmp200W

# Summary

Integrating the MA5332MS from infineon, a super efficient and compact class D amplifier. With a ADAU1761 DSP, a simple to use DSP for consumer audio applications. A TPS26750 to control USB PD 3.1 EPR power supplies for up to 240W of DC power. RP2350 microcontroller for easy high level control of the system.

The goal is to design a compact and efficient board that can supply a wide range of power to the class D amplifier, include line in and out for easy audio amplification, Digital audio in over usb-c should be possible in the future with the RP2350 and the DSP. Which could have some signal processing benefits for driving a HUB75 matrix panel in real time. Including a quality DSP such as the ADAU1761 DSP should allow us to explore signal processing techniques to achieve optimal results for many speaker setups.

#Power Supply

The USB PD 3.1 EPR can supply a maximum of 48V@5A for 240 watts dc. Even lower settings such as 20V/3A is a common laptop charging standard and many people already own USB-C bricks that can supply this which should be enough for some decent audio output. The highest commonly available is 28V@5A which is uncommon but available from many manufacturers online. 48V@5A is hard to find and expensive although I do plan on testing it on the first revision. 

# Major Circuits

-RP2350 microcontroller

-TI TPS26750 PD 3.1 EPR controller and power management system

-MA5332MS class D amplifier (up to 200W)

-ADAU1761 consumer audio DSP w/ graphical interface (programmed over serial from RP2350)


# Cool features

-HUB75 interface (for driving LED matrix panels)

-USB-C digital audio in (24 bit/96kHz should be doable, keeps signal pristine)

-Precision signal aquisition with ADS131 delta-sigma ADC

-Line In

-Run without a heatsink at lower powers
