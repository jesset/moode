#!/bin/bash

# 1. Run cyclictest
#sudo cyclictest  -l10000000 -m -Sp99 -i200 -h100 -q | tee output
sudo cyclictest  --duration=6h -m -Sp99 -i200 -h100 -q | tee output

# get kernel ver
kernelver=$(uname -r)

# 2. Get maximum latency
max=`grep "Max Latencies" output | tr " " "\n" | sort -n | tail -1 | sed s/^0*//`

# 3. Grep data lines, remove empty lines and create a common field separator
grep -v -e "^#" -e "^$" output | tr " " "\t" >histogram

# 4. Set the number of cores, for example
cores=4

# 5. Create two-column data sets with latency classes and frequency values for each core, for example
for i in `seq 1 $cores`
do
  column=`expr $i + 1`
  cut -f1,$column histogram >histogram$i
done

# 6. Create plot command header
echo -n -e "set title \"Latency plot - kernel:${kernelver}\"\n\
set terminal svg  enhanced font \"Menlo,8\" \n\
set output \"latency.svg\"\n\
set grid\n\
set xlabel \"Latency (us), max $max us\"\n\
set logscale y\n\
set xrange [0:100]\n\
set yrange [0.8:*]\n\
set ylabel \"Number of latency samples\"\n\
plot " >plotcmd

# 7. Append plot command data references
for i in `seq 1 $cores`
do
  if test $i != 1
  then
    echo -n ", " >>plotcmd
  fi
  cpuno=`expr $i - 1`
  if test $cpuno -lt 10
  then
    title=" CPU$cpuno"
   else
    title="CPU$cpuno"
  fi
  echo -n "\"histogram$i\" using 1:2 title \"$title\" with histeps" >>plotcmd
done

# 8. Execute plot command
echo "---------"
echo "Finished, pls run:"
echo "gnuplot -persist <plotcmd"
echo "---------"
