#!/bin/bash
# 启动子川助手 web 实例（3081，独立 profile，日志 /tmp/zichuan-web.log）
bash "$(dirname "$0")/zkill.sh" >/dev/null 2>&1
sleep 1
cd /root || exit 1
setsid nohup /opt/node/bin/node /opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js --profile zichuan --no-open --port 3081 \
  > /tmp/zichuan-web.log 2>&1 < /dev/null &
echo "started pid=$!"
