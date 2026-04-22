#!/bin/bash
# OrcaShell cluster teardown
set -e
echo "Destroying OrcaShell cluster..."
kind delete cluster --name orcashell
rm -rf /tmp/orcashell-certs
echo "Done."
 
