#!/bin/bash
# 启动 JMComic 桌面版（macOS）
#
# JVM 参数说明：
#   MaxRAMPercentage=25  —— 默认堆上限是物理内存的 1/4 但不主动归还，
#                            配合 G1 的定期归还才能把常驻内存压下来
#   G1PeriodicGCInterval —— 空闲时触发 GC，把空闲堆还给系统
#   MaxHeapFreeRatio     —— 堆空闲超过该比例就收缩
cd "$(dirname "$0")"
exec java --enable-native-access=ALL-UNNAMED \
    -XX:MaxRAMPercentage=25 \
    -XX:+UseG1GC \
    -XX:G1PeriodicGCInterval=15000 \
    -XX:MinHeapFreeRatio=10 \
    -XX:MaxHeapFreeRatio=30 \
    -jar jmcomic-desktop-support/target/jmcomic-desktop-support-1.1.7.jar
