#! /bin/bash
docker run --rm \
  -e AWS_REGION=us-east-1 \
  xray-rocker-model:latest \
  Rscript plumber.R sample.json