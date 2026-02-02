#!/bin/bash
apt update
curl -sSL https://dot.net/v1/dotnet-install.sh | bash
apt install -y libicu-dev git
echo 'export PATH="$HOME/.dotnet:$PATH"' >> ~/.bashrc
source ~/.bashrc
echo '{
  "runtimeOptions": {
    "configProperties": {
      "System.GC.HeapHardLimit": 268435456
    }
  }
}' > runtimeconfig.template.json
dotnet --info
git clone https://gh-proxy.org/https://github.com/NirvanaTec/Fantnel.git
dotnet build Fantnel.slnx
echo "sb"
