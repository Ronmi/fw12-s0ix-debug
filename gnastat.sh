#!/bin/bash
lspci -vv -s 00:08.0 | grep "Status: D"
