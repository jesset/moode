#!/bin/bash


echo
echo "--------- Version ---------"
cat /sys/firmware/devicetree/base/model;echo
#cat /sys/firmware/devicetree/base/serial-number
sudo vcgencmd version

echo
echo "--------- Memory ---------"
sudo vcgencmd get_mem arm 
sudo vcgencmd get_mem gpu

echo
echo "--------- Voltages ---------"
for id in core sdram_c sdram_i sdram_p ; do
    echo -e "$id:\t$(sudo vcgencmd measure_volts $id)" ; 
 done

echo
echo "--------- Frequencis ---------"
for src in arm core h264 isp v3d uart pwm emmc pixel vec hdmi dpi ; do 
  echo -e "$src:\t$(sudo vcgencmd measure_clock $src)" ; 
done

# echo
# echo "--------- Codecs ---------"
# for codec in H264 MPG2 WVC1 MPG4 MJPG WMV9 ; do 
#     echo -e "$codec:\t$(vcgencmd codec_enabled $codec)" ; 
# done

echo
echo "--------- config int/str ---------"
sudo vcgencmd get_config int
sudo vcgencmd get_config str
#sudo vcgencmd get_config config

echo
echo "--------- Temperature ---------"
echo CPU $(awk '{print $1/1000," C"}' /sys/class/thermal/thermal_zone0/temp)
echo GPU $(sudo vcgencmd measure_temp)

