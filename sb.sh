#!/bin/bash
apt update
curl -sSL https://dot.net/v1/dotnet-install.sh | bash
apt install -y libicu-dev git
echo 'export PATH="$HOME/.dotnet:$PATH"' >> ~/.bashrc
source ~/.bashrc
export DOTNET_GCHeapHardLimit=0x10000000  # 256MB
export DOTNET_GCHeapHardLimitPercent=50
dotnet --info
git clone https://gh-proxy.org/https://github.com/NirvanaTec/Fantnel.git
dotnet build Fantnel.slnx
dotnet publish -c Release -r linux-arm64 --self-contained true
echo "sb"
