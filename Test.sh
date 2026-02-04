#!/bin/bash

# ==============================================================================
# Minecraft Mod 开发环境自动化配置脚本
# 集成功能：
# 1. 自动内存优化
# 2. 智能 Git 拉取 (自动修正 gradlew 权限)
# 3. 存储挂载检测
# 4. JDK/Gradle/Maven 一键管理
# 5. 完善的 GitHub 加速下载，支持自定义镜像
# 6. 自定义 JDK 版本安装与选择
# 7. 自定义 JDK 安装
# 8. 完善的构建功能
# 9. 自动安装依赖和工具
# ==============================================================================

# --- 全局颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 辅助函数 ---

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- 安装工具和依赖 ---
install_tool() {
    local tool=$1
    if ! command -v "$tool" &> /dev/null; then
        log_info "$tool 未安装，正在安装..."
        sudo apt update && sudo apt install -y "$tool"
    fi
}

# --- 自动内存优化配置 ---
configure_memory_safe() {
    local GRADLE_USER_HOME="$HOME/.gradle"
    local PROP_FILE="$GRADLE_USER_HOME/gradle.properties"

    # 确保 gradle 配置目录存在
    mkdir -p "$GRADLE_USER_HOME"

    # 检查是否已经配置过
    if grep -q "org.gradle.jvmargs" "$PROP_FILE" 2>/dev/null; then
        return
    fi

    log_info "正在配置内存优化防止闪退..."

    # 配置内存优化
    cat > "$PROP_FILE" << EOF
# Auto-generated for Termux
org.gradle.jvmargs=-Xmx2048m -XX:MaxMetaspaceSize=512m -XX:+HeapDumpOnOutOfMemoryError -Dfile.encoding=UTF-8
org.gradle.daemon=false
org.gradle.parallel=false
org.gradle.caching=true
EOF
    log_success "内存保护已开启！(已配置 ~/.gradle/gradle.properties)"
}

# --- 检查并挂载存储 ---
check_sdcard_access() {
    if [ ! -w "/sdcard" ]; then
        log_warn "检测到 /sdcard 不可写或不存在！"
        echo -e "${YELLOW}警告：你可能忘记挂载手机存储了。${NC}"
        echo "建议退出后使用以下命令启动 Proot："
        echo -e "${CYAN}proot-distro login ubuntu --bind /sdcard:/sdcard${NC}"
        read -p "是否继续使用容器内部空间？ (y/n): " confirm
        [[ "$confirm" != "y" ]] && return 1
    fi
    return 0
}

# --- 安装并切换 JDK 版本 ---
install_and_switch_jdk() {
    clear
    echo "=== 安装并切换 JDK 版本 ==="

    echo "请选择要安装的 JDK 版本："
    echo "1. JDK 8"
    echo "2. JDK 17"
    echo "3. JDK 21"
    echo "4. 自定义安装 JDK"
    echo "5. 返回"
    read -p "请输入选项 (1/2/3/4/5): " choice

    case $choice in
        1)
            install_tool openjdk-8-jdk
            update-alternatives --config java
            ;;
        2)
            install_tool openjdk-17-jdk
            update-alternatives --config java
            ;;
        3)
            install_tool openjdk-21-jdk
            update-alternatives --config java
            ;;
        4)
            install_custom_jdk
            ;;
        5) return ;;
        *)
            log_error "无效选项，请重新选择。"
            ;;
    esac
}

# --- 自定义安装 JDK ---
install_custom_jdk() {
    clear
    echo "=== 自定义安装 JDK ==="
    
    read -p "请输入 JDK 安装包的下载链接 (或本地路径)： " jdk_url_or_path

    if [[ -z "$jdk_url_or_path" ]]; then
        log_error "安装包路径不能为空！"
        return
    fi

    # 处理 URL 或本地路径
    if [[ "$jdk_url_or_path" =~ ^https?:// ]]; then
        log_info "正在从 URL 下载 JDK..."
        wget -q --show-progress "$jdk_url_or_path" -O jdk.tar.gz
        [[ $? -ne 0 ]] && log_error "下载 JDK 失败，请检查 URL。" && return
    elif [[ -f "$jdk_url_or_path" ]]; then
        log_info "使用本地安装包 $jdk_url_or_path 安装 JDK..."
        cp "$jdk_url_or_path" jdk.tar.gz
    else
        log_error "无效的 JDK 路径或 URL。"
        return
    fi

    # 解压 JDK 包
    log_info "正在解压 JDK 安装包..."
    tar -xzf jdk.tar.gz -C /opt
    local jdk_dir=$(ls -d /opt/jdk-*/)
    [[ ! -d "$jdk_dir" ]] && log_error "解压失败，找不到 JDK 目录。" && return

    # 配置环境变量
    log_info "配置 JDK 环境变量..."
    echo "export JAVA_HOME=$jdk_dir" >> ~/.bashrc
    echo "export PATH=\$JAVA_HOME/bin:\$PATH" >> ~/.bashrc
    source ~/.bashrc

    # 设置默认 Java 版本
    log_info "设置默认 JDK..."
    update-alternatives --install /usr/bin/java java "$jdk_dir/bin/java" 1
    update-alternatives --set java "$jdk_dir/bin/java"
    update-alternatives --install /usr/bin/javac javac "$jdk_dir/bin/javac" 1
    update-alternatives --set javac "$jdk_dir/bin/javac"

    log_success "自定义 JDK 安装并配置完成！"
}

# --- 拉取 GitHub 项目 ---
git_pull_with_custom_accel() {
    clear
    echo "=== Git 拉取并构建项目 (自定义加速版) ==="
    
    read -p "是否启用自定义 GitHub 加速镜像？ (y/n): " use_custom_accel
    custom_url="https://github.com"
    
    if [[ "$use_custom_accel" == "y" ]]; then
        custom_url="https://gh-proxy.org/https://github.com"
        log_info "启用加速镜像: $custom_url"
    else
        log_info "使用原始 GitHub 地址: $custom_url"
    fi

    read -p "请输入 GitHub 仓库地址 (例如 https://github.com/user/repo.git): " git_url
    [[ -z "$git_url" ]] && return

    # 替换 GitHub URL 为加速镜像 URL
    git_url="${git_url/https:\/\/github.com/$custom_url}"
    log_info "使用加速源: $git_url"

    # 获取项目名
    local repo_name=$(basename "$git_url" .git)
    echo ""
    echo "请选择存储位置："
    echo "1. 存放在容器内部 (~/projects/$repo_name)"
    echo "2. 存放在手机存储 (/sdcard/Projects/$repo_name)"
    read -p "选择 (1/2): " loc_choice

    local final_path=""
    if [ "$loc_choice" == "2" ]; then
        if ! check_sdcard_access; then return; fi
        mkdir -p "/sdcard/Projects"
        final_path="/sdcard/Projects/$repo_name"
    else
        mkdir -p "$HOME/projects"
        final_path="$HOME/projects/$repo_name"
    fi

    if [ -d "$final_path" ]; then
        log_warn "目录已存在: $final_path"
        read -p "是否更新该目录 (git pull)? (y/n): " update_confirm
        if [[ "$update_confirm" == "y" ]]; then
            cd "$final_path" && git pull
        else
            return
        fi
    else
        log_info "正在克隆到: $final_path"
        git clone "$git_url" "$final_path"
    fi

    if [ $? -eq 0 ]; then
        log_success "项目已就绪！"
        read -p "是否立即开始构建? (y/n): " build_now
        if [[ "$build_now" == "y" ]]; then
            do_build_logic "$final_path"
        fi
    else
        log_error "Git Clone 失败，请检查网络连接。"
    fi
}

# --- 构建项目 ---
do_build_logic() {
    local target_dir="$1"
    [[ ! -d "$target_dir" ]] && log_error "目录不存在: $target_dir" && return

    cd "$target_dir" || return
    # 赋予 gradlew 权限
    [[ -f "gradlew" ]] && chmod +x gradlew

    local build_type="unknown"
    [[ -f "build.gradle" ]] && build_type="gradle"
    [[ -f "pom.xml" ]] && build_type="maven"

    echo -e "-------------------------------------------"
    echo -e "当前项目: ${CYAN}$(basename "$target_dir")${NC}"
    echo -e "项目类型: ${GREEN}$build_type${NC}"
    echo -e "-------------------------------------------"

    echo "请选择构建操作："
    echo "1. 构建 (Build)"
    echo "2. 清理 (Clean)"
    echo "3. 仅下载依赖"
    echo "4. 构建并生成 Jar 包"
    echo "5. 返回"
    read -p "请选择操作: " action

    [[ "$action" == "5" ]] && return

    local start_time=$(date +%s)
    
    case $build_type in
        gradle)
            local wrapper="./gradlew"
            [[ ! -f "$wrapper" ]] && wrapper="gradle"
            local args="--no-daemon --stacktrace --info"
            
            case $action in
                1) $wrapper build $args ;;
                2) $wrapper clean $args ;;
                3) $wrapper dependencies $args ;;
                4) $wrapper build -x test $args ;;
            esac
            ;;
        maven)
            case $action in
                1) mvn package ;;
                2) mvn clean ;;
                3) mvn dependency:resolve ;;
                4) mvn clean package -DskipTests ;;
            esac
            ;;
        *)
            log_error "无法识别该项目类型，无法构建。"
            ;;
    esac

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log_info "操作耗时: ${duration} 秒"
    read -p "按回车继续..."
}

# --- 基础环境安装 ---
install_dependencies() {
    clear
    log_info "检查系统依赖..."
    local pkgs="git wget unzip nano curl openjdk-17-jdk"
    
    for pkg in $pkgs; do
        install_tool "$pkg"
    done
    configure_memory_safe
}

# --- 主菜单 ---
main_menu() {
    while true; do
        clear
        echo '========================================='
        echo -e "   ${CYAN}MC Mod 开发环境配置${NC}"
        echo '========================================='
        
        local java_ver="未安装"
        if command -v java &> /dev/null; then
            java_ver=$(java -version 2>&1 | head -1 | cut -d'"' -f2)
        fi
        echo -e "Java版本: ${GREEN}$java_ver${NC}"
        echo '-----------------------------------------'
        
        echo "1. 安装并切换 JDK 版本"
        echo "2. 拉取并构建项目"
        echo "3. 手动构建本地项目"
        echo "4. 退出"
        echo ""
        read -p "请输入选项: " choice

        case $choice in
            1) install_and_switch_jdk ;;
            2) git_pull_with_custom_accel ;;
            3) 
                read -p "请输入项目路径: " manual_path
                do_build_logic "$manual_path" 
                ;;
            4) exit 0 ;;
            *) ;;
        esac
    done
}

# --- 执行主菜单 ---
install_dependencies
main_menu
