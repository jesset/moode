#!/bin/bash

if [[ -n $1 ]];then
  cls_exclude=$1
else
  cls_exclude=TS
fi

for core in 0 1 2 3;do
  echo "#### RT threads @Core $core :"
  ps  -eL -o class,pid,lwp,psr,rtprio,pri,nice,sched,pcpu,comm,args | awk -v cid=$core '($4==cid || NR==1){print }' | grep -v ${cls_exclude}
  echo
done

