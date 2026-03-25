#!/usr/bin/env python3
import sys
data = open(sys.argv[1], 'rb').read()
words = []
for i in range(0, len(data), 4):
    w = int.from_bytes(data[i:i+4], 'little')
    words.append(f'{w:08x}')
# Pad to 4096 words (16KB)
while len(words) < 4096:
    words.append('00000000')
for w in words:
    print(w)
