#!/usr/bin/env python

import sys
import re

fill_values_filename = sys.argv[1]
base_filename = sys.argv[2]

fill_values = [line for line in
        [line.strip() for line in open(fill_values_filename, 'r').readlines()]
        if len(line) > 0 and line[0] != '#']
result_values = open(base_filename, 'r').readlines()

fill_section = None
for line in fill_values:
    line = line.rstrip()
    if line[0] == '[':
        fill_section = line[1:-1]
    else:
        keyname = line.split('=')[0].rstrip()
        resline_re = re.compile('#?\s*' + keyname + '\s*=')
        result_section = None
        value_found = False
        for i, resline in enumerate(result_values):
            if len(resline) > 0:
                if resline[0] == '[':
                    result_section = resline[1:-2]
                elif fill_section == result_section and resline_re.match(resline):
                    result_values[i] = line + '\n'
                    value_found = True
        if not value_found:
            insert_position = None
            for i, resline in enumerate(result_values):
                if len(resline) > 0:
                    if resline[0] == '[':
                        result_section = resline[1:-2]
                        if fill_section == result_section:
                            insert_position = i + 2
            if insert_position is not None:
                result_values.insert(insert_position, line + '\n')
            else:
                sys.stderr.write('SECTION {0} NOT FOUND!!!!\n'.format(fill_section))

for line in result_values:
    sys.stdout.write(line)
