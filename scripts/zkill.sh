#!/bin/bash
# 结束 3081 上的 zichuan 实例：只匹配以 node 启动的 dsh 进程，避免误杀调用者自己。
for d in /proc/[0-9]*; do
  pid=${d#/proc/}
  cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
  case "$cmd" in
    /opt/node/bin/node*dsh/lib/bin.js*--profile\ zichuan*)
      echo "kill $pid"
      kill -9 "$pid" 2>/dev/null
      ;;
  esac
done
exit 0
