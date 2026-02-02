set -e

echo "开始系统配置..."

# 1. 安装 .NET SDK
echo "正在安装 .NET SDK..."
curl -sSL https://dot.net/v1/dotnet-install.sh | bash

# 2. 安装必要依赖
echo "正在安装依赖包..."
apt-get update && apt-get install -y libicu-dev git

# 3. 配置环境变量
echo "配置环境变量..."
if ! grep -q 'export PATH="$HOME/.dotnet:$PATH"' ~/.bashrc; then
    echo 'export PATH="$HOME/.dotnet:$PATH"' >> ~/.bashrc
fi
source ~/.bashrc

# 4. 验证安装
echo "验证安装..."
dotnet --info

echo "安装完成！"
