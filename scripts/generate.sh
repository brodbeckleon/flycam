#!/bin/bash
# Generates Apps/FlyCam.xcodeproj from project.yml.
source "$(dirname "$0")/common.sh"
generate_project
echo "generated $PROJECT"
