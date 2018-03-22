#!/bin/bash

echo CPU $(awk '{print $1/1000," C"}' /sys/class/thermal/thermal_zone0/temp)
echo GPU $(sudo vcgencmd measure_temp)

