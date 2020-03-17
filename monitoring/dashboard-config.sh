#!/bin/bash

ls $1 | awk -F. '{ print $1 ":\n  file: dashboards/custom/" $1 "." $2 }'