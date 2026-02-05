#!/usr/bin/env bash
# mcdev_final.sh (完整版)
# Ultimate single-file Minecraft Mod pipeline (Termux-friendly)
#  - 全功能整合：JDK自动安装、Gradle配置、Mod构建/混淆/反混淆、发布等
#  - 兼容Termux/ Linux (Debian/Ubuntu/CentOS)
#
# Usage:
#   chmod +x mcdev_final.sh
#   ./mcdev_final.sh
#
# IMPORTANT: 仅用于合法/合规的Minecraft Mod开发场景

set -euo pipefail
IFS=$'\n\t'

# -------------------------
# 颜色定义 & 日志辅助函数
# -------------------------
RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; BLUE="\033[1;34m"; CYAN="\033[1;36m"; RESET="\033[0m"
info(){ echo -e "${BLUE}[INFO]${RESET} $*"; }
ok(){ echo -e "${GREEN}[OK]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
err(){ echo -e "${RED}[ERR]${RESET} $*"; }

# -------------------------
# 路径 & 全局变量
# -------------------------
BASE="$HOME/modpipeline"
PROJECTS_LOCAL="$HOME/projects"
PROJECTS_SDCARD="$HOME/storage/shared/Projects"   # Termux共享路径
TOOLS_DIR="$BASE/tools"
PROGUARD_DIR="$TOOLS_DIR/proguard"
PROGUARD_JAR="$PROGUARD_DIR/proguard.jar"
ZKM_DIR="$TOOLS_DIR/zelixkiller"
ZKM_JAR="$ZKM_DIR/zkm.jar"
CFR_DIR="$TOOLS_DIR/cfr"
CFR_JAR="$CFR_DIR/cfr.jar"
STRINGER_JAR="$HOME/stringer.jar"   # 可选：字符串混淆工具
CONFIG_FILE="$HOME/.mcdev_env.conf"
GRADLE_USER_HOME="$HOME/.gradle"
SDCARD_DOWNLOAD="/sdcard/Download"
ARCH=$(uname -m)

IS_TERMUX=false
PKG_INSTALL_CMD=""

# 检测运行环境 & 包管理器
if command -v pkg >/dev/null 2>&1; then
  IS_TERMUX=true
  PKG_INSTALL_CMD="pkg install -y"
elif command -v apt >/dev/null 2>&1; then
  PKG_INSTALL_CMD="sudo apt-get install -y"
elif command -v yum >/dev/null 2>&1; then
  PKG_INSTALL_CMD="sudo yum install -y"
fi

# -------------------------
# 基础工具函数
# -------------------------
ensure_dir(){ mkdir -p "$1" || err "创建目录失败: $1"; }
run_and_log(){ 
  local log="$1"; shift 
  "$@" 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}

# -------------------------
# 配置加载/保存
# -------------------------
load_config(){
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  fi
  if [[ -z "${PROJECT_BASE:-}" ]]; then
    if [[ -d "$PROJECTS_SDCARD" ]]; then 
      PROJECT_BASE="$PROJECTS_SDCARD" 
    else 
      PROJECT_BASE="$PROJECTS_LOCAL" 
    fi
  fi
}

save_config(){
  ensure_dir "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<EOF
PROJECT_BASE="$PROJECT_BASE"
EOF
  ok "配置保存至 $CONFIG_FILE"
}

# -------------------------
# Termux存储挂载检查
# -------------------------
check_storage_and_hint(){
  if [[ "$IS_TERMUX" == "true" ]]; then
    if [[ ! -d "$HOME/storage/shared" && ! -d "/sdcard" ]]; then
      warn "Termux 未挂载共享存储 (~/storage/shared 或 /sdcard)。"
      read -p "现在运行 termux-setup-storage 授权？(y/N): " yn
      if [[ "$yn" =~ ^[Yy]$ ]]; then
        termux-setup-storage
        sleep 2
      else
        warn "将使用本地目录作为 fallback。"
      fi
    fi
  fi
}

# -------------------------
# 基础CLI工具检查 & 安装
# -------------------------
ensure_basic_tools(){
  local need=(git wget curl unzip zip tar sed awk javac)
  local miss=()
  for t in "${need[@]}"; do
    if ! command -v "$t" >/dev/null 2>&1; then 
      miss+=("$t") 
    fi
  done
  if [[ ${#miss[@]} -gt 0 ]]; then
    warn "检测到缺失工具: ${miss[*]}"
    if [[ -n "$PKG_INSTALL_CMD" ]]; then
      info "尝试通过包管理器安装..."
      $PKG_INSTALL_CMD "${miss[@]}" || warn "自动安装失败，请手动安装: ${miss[*]}"
    else
      warn "无法自动安装，请手动安装: ${miss[*]}"
    fi
  fi
}

# -------------------------
# JDK 自动下载 & 自定义安装
# -------------------------
auto_install_jdk(){
  if command -v java >/dev/null 2>&1; then
    info "检测到 Java: $(java -version 2>&1 | head -n1)"
    read -p "保留现有 Java？(y/N): " keep
    [[ "$keep" =~ ^[Yy]$ ]] && return 0
  fi

  echo "请选择 JDK 版本：1)8  2)17(推荐)  3)21  4) 自定义 URL/本地包  5) 取消"
  read -p "选择 [1-5]: " c
  case "$c" in
    1) ver=8 ;;
    2) ver=17 ;;
    3) ver=21 ;;
    4)
      read -p "输入 JDK 下载 URL 或 本地路径 (tar.gz/zip): " src
      install_custom_jdk "$src"
      return $?
      ;;
    *) warn "取消 JDK 安装"; return 1 ;;
  esac

  case "$ARCH" in
    aarch64|arm64) arch_dl="aarch64" ;;
    x86_64|amd64) arch_dl="x64" ;;
    *) arch_dl="x64" ;;
  esac

  dest="$HOME/jdk-$ver"
  ensure_dir "$dest"
  # 修复 Adoptium API URL (补充project参数)
  api_url="https://api.adoptium.net/v3/binary/latest/${ver}/ga/linux/${arch_dl}/jdk/hotspot/normal/eclipse?project=jdk"
  info "通过 Adoptium API 下载 JDK $ver ..."
  tmp="/tmp/jdk${ver}.tar.gz"
  
  if wget -O "$tmp" "$api_url"; then
    info "下载完成，正在解压..."
    tar -xzf "$tmp" -C "$dest" --strip-components=1 || { err "解压失败"; return 1; }
    rm -f "$tmp"
    
    # 兼容 bash/zsh rc文件
    shell_rc="$HOME/.bashrc"
    [[ -n "${ZSH_VERSION:-}" ]] && shell_rc="$HOME/.zshrc"
    
    # 避免重复写入环境变量
    if ! grep -q "# mcdev jdk $ver" "$shell_rc" 2>/dev/null; then
      {
        echo ""
        echo "# mcdev jdk $ver"
        echo "export JAVA_HOME=\"$dest\""
        echo 'export PATH=$JAVA_HOME/bin:$PATH'
      } >> "$shell_rc"
      ok "已写入 $shell_rc（重新打开终端或 source $shell_rc 生效）"
    fi
    
    export JAVA_HOME="$dest"; export PATH="$JAVA_HOME/bin:$PATH"
    ok "JDK $ver 安装完成"
    return 0
  else
    err "JDK 下载失败 (URL: $api_url)"
    return 1
  fi
}

install_custom_jdk(){
  local src="$1"
  if [[ -z "$src" ]]; then err "未提供 URL/路径"; return 1; fi
  
  # 下载远程JDK包
  if [[ "$src" =~ ^https?:// ]]; then
    tmp="/tmp/custom_jdk_$(date +%s).tar.gz"
    info "下载自定义 JDK..."
    if ! wget -O "$tmp" "$src"; then err "下载失败"; return 1; fi
    src="$tmp"
  fi
  
  # 检查文件存在性
  if [[ ! -f "$src" ]]; then err "文件不存在: $src"; return 1; fi
  
  dest="$HOME/jdk-custom-$(date +%s)"
  ensure_dir "$dest"
  info "解压到 $dest ..."
  
  # 解压适配不同格式
  case "$src" in
    *.tar.gz|*.tgz) tar -xzf "$src" -C "$dest" --strip-components=1 ;;
    *.zip) unzip -q "$src" -d "$dest" ;;
    *) err "不支持的压缩格式"; return 1 ;;
  esac
  
  # 写入环境变量
  shell_rc="$HOME/.bashrc"
  [[ -n "${ZSH_VERSION:-}" ]] && shell_rc="$HOME/.zshrc"
  
  if ! grep -q "# mcdev custom jdk" "$shell_rc" 2>/dev/null; then
    {
      echo ""
      echo "# mcdev custom jdk"
      echo "export JAVA_HOME=\"$dest\""
      echo 'export PATH=$JAVA_HOME/bin:$PATH'
    } >> "$shell_rc"
  fi
  
  export JAVA_HOME="$dest"; export PATH="$JAVA_HOME/bin:$PATH"
  ok "自定义 JDK 已安装并写入 $shell_rc"
  return 0
}

# -------------------------
# ProGuard 自动下载
# -------------------------
ensure_proguard(){
  if [[ -f "$PROGUARD_JAR" ]]; then ok "ProGuard 就绪"; return 0; fi
  info "正在下载 ProGuard..."
  ensure_dir "$PROGUARD_DIR"
  
  PG_VER="7.4.1"
  PG_TGZ="proguard-${PG_VER}.tar.gz"
  PG_URL="https://github.com/Guardsquare/proguard/releases/download/v${PG_VER}/${PG_TGZ}"
  tmp="$PROGUARD_DIR/$PG_TGZ"
  
  if wget -O "$tmp" "$PG_URL"; then
    tar -xzf "$tmp" -C "$PROGUARD_DIR" --strip-components=1
    if [[ -f "$PROGUARD_DIR/lib/proguard.jar" ]]; then
      mv "$PROGUARD_DIR/lib/proguard.jar" "$PROGUARD_JAR"
      rm -rf "$PROGUARD_DIR/lib" "$PROGUARD_DIR/bin" "$PROGUARD_DIR/docs"
      rm -f "$tmp"
      ok "ProGuard 已下载: $PROGUARD_JAR"
      return 0
    fi
  fi
  err "ProGuard 下载或解压失败"
  return 1
}

# -------------------------
# ZKM (ZelixKiller) 自动下载
# -------------------------
ensure_zkm(){
  if [[ -f "$ZKM_JAR" ]]; then ok "ZKM 就绪"; return 0; fi
  ensure_dir "$ZKM_DIR"
  
  ZKM_URL_DEFAULT="https://raw.githubusercontent.com/fkbmr/sb/main/zkm.jar"
  read -p "请输入 ZKM 下载 URL (回车使用默认): " zurl
  zurl=${zurl:-$ZKM_URL_DEFAULT}
  
  info "下载 ZKM..."
  if wget -O "$ZKM_JAR" "$zurl"; then 
    ok "ZKM 已下载: $ZKM_JAR"
    return 0
  else 
    err "ZKM 下载失败"
    return 1
  fi
}

# -------------------------
# CFR 反编译器 自动下载
# -------------------------
ensure_cfr(){
  if [[ -f "$CFR_JAR" ]]; then ok "CFR 就绪"; return 0; fi
  ensure_dir "$CFR_DIR"
  
  CFR_URL="https://www.benf.org/other/cfr/cfr-0.152.jar"
  info "下载 CFR..."
  if wget -O "$CFR_JAR" "$CFR_URL"; then 
    ok "CFR 已下载"
    return 0
  else 
    err "CFR 下载失败"
    return 1
  fi
}

# -------------------------
# Gradle Wrapper 生成 & ZIP安装
# -------------------------
ensure_gradle_wrapper(){
  if [[ -f "./gradlew" ]]; then 
    chmod +x ./gradlew 2>/dev/null || true
    ok "gradlew 已存在"
    return 0
  fi
  
  warn "gradlew 不存在，尝试生成 wrapper..."
  if ! command -v gradle >/dev/null 2>&1; then
    warn "系统未安装 Gradle"
    if [[ -n "$PKG_INSTALL_CMD" ]]; then
      $PKG_INSTALL_CMD gradle || warn "自动安装 gradle 失败"
    fi
  fi
  
  if command -v gradle >/dev/null 2>&1; then
    gradle wrapper || { err "gradle wrapper 生成失败"; return 1; }
    chmod +x ./gradlew
    ok "Gradle wrapper 生成完成"
    return 0
  fi
  return 1
}

install_gradle_from_zip(){
  read -p "请输入 Gradle ZIP 本地路径或下载 URL: " zippath
  [[ -z "$zippath" ]] && { warn "取消"; return 1; }
  zippath="${zippath/#\~/$HOME}"
  
  # 下载远程ZIP
  if [[ "$zippath" =~ ^https?:// ]]; then
    tmp="/tmp/gradle_$(date +%s).zip"
    info "下载 Gradle ZIP..."
    wget -O "$tmp" "$zippath" || { err "下载失败"; return 1; }
    zippath="$tmp"
  fi
  
  # 检查文件存在性
  if [[ ! -f "$zippath" ]]; then err "文件不存在: $zippath"; return 1; fi
  
  # 确定安装目录
  dest="/opt/gradle"
  [[ ! -w /opt ]] && dest="$HOME/.local/gradle"
  ensure_dir "$dest"
  
  # 解压
  unzip -q -o "$zippath" -d "$dest"
  
  # 定位Gradle目录
  folder=$(ls "$dest" | grep -E "^gradle-[0-9.]+" | head -n1)
  [[ -z "$folder" ]] && folder=$(ls "$dest" | head -n1)
  
  # 创建软链接
  if [[ -x "$dest/$folder/bin/gradle" ]]; then
    ensure_dir "$HOME/.local/bin"
    ln -sf "$dest/$folder/bin/gradle" /usr/local/bin/gradle 2>/dev/null || 
    ln -sf "$dest/$folder/bin/gradle" "$HOME/.local/bin/gradle"
    ok "Gradle 已安装到 $dest/$folder"
    return 0
  fi
  
  err "Gradle 安装后未找到 bin/gradle"
  return 1
}

# -------------------------
# Maven 检查 & 安装
# -------------------------
ensure_maven(){
  if command -v mvn >/dev/null 2>&1; then ok "Maven 已安装"; return 0; fi
  if [[ -n "$PKG_INSTALL_CMD" ]]; then
    info "尝试安装 Maven..."
    $PKG_INSTALL_CMD maven || { warn "自动安装 Maven 失败，请手动安装"; return 1; }
    ok "Maven 安装完成"; return 0
  fi
  warn "无法自动安装 Maven，请手动安装"
  return 1
}

# -------------------------
# Gradle 优化 (镜像/内存)
# -------------------------
configure_gradle_optimization(){
  ensure_dir "$GRADLE_USER_HOME"
  PROPS="$GRADLE_USER_HOME/gradle.properties"
  
  # 自动计算堆内存（兼容无/proc/meminfo系统）
  mem_mb=2048
  if [[ -f /proc/meminfo ]]; then
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    mem_mb=$((mem_kb/1024))
  fi
  xmx=$((mem_mb*70/100))
  (( xmx > 4096 )) && xmx=4096
  
  # 写入JVM参数
  if [[ -f "$PROPS" ]]; then
    sed -i '/org.gradle.jvmargs/d' "$PROPS" 2>/dev/null
  fi
  echo "org.gradle.jvmargs=-Xmx${xmx}m -Dfile.encoding=UTF-8" >> "$PROPS"
  ok "写入 $PROPS (-Xmx ${xmx}m)"
  
  # 写入镜像配置
  INIT="$GRADLE_USER_HOME/init.gradle"
  cat > "$INIT" <<'EOF'
allprojects {
  repositories {
    maven { url 'https://maven.aliyun.com/repository/public/' }
    mavenLocal()
    mavenCentral()
    google()
  }
}
EOF
  ok "写入 Gradle 镜像配置: $INIT"
}

# -------------------------
# Git克隆 (带镜像加速)
# -------------------------
clone_repo(){
  read -p "仓库 (user/repo 或 完整 URL): " repo_input
  [[ -z "$repo_input" ]] && { warn "取消"; return 1; }
  
  # 构建克隆URL
  if [[ "$repo_input" =~ ^https?:// ]]; then 
    repo_url="$repo_input"
  else
    echo "是否使用镜像加速?"
    echo "1) gh-proxy.org   2) ghproxy.com   3) hub.fastgit.xyz   4) 自定义   5) 不使用"
    read -p "选择 [1-5]: " proxy
    
    case "$proxy" in
      1) base="https://gh-proxy.org/https://github.com/" ;;
      2) base="https://ghproxy.com/https://github.com/" ;;
      3) base="https://hub.fastgit.xyz/" ;;
      4) read -p "输入镜像前缀: " custom; base="$custom" ;;
      *) base="https://github.com/" ;;
    esac
    repo_url="${base}${repo_input}.git"
  fi

  # 选择存储位置
  load_config
  echo "选择存放位置 (默认: $PROJECT_BASE):"
  echo "1) 本地: $PROJECTS_LOCAL"
  [[ "$IS_TERMUX" == "true" ]] && echo "2) 共享: $PROJECTS_SDCARD"
  echo "3) 自定义路径"
  read -p "选择 [Enter=默认]: " choice
  
  case "$choice" in
    2) target="$PROJECTS_SDCARD" ;;
    3) read -p "输入目标路径: " customp; target="$customp" ;;
    *) target="$PROJECT_BASE" ;;
  esac
  
  ensure_dir "$target"
  save_config
  
  # 克隆仓库
  repo_name=$(basename "$repo_input" .git)
  info "克隆到: $target/$repo_name"
  
  git clone "$repo_url" "$target/$repo_name" || { err "git clone 失败"; return 1; }
  ok "克隆完成"
  
  # 进入目录 & 生成gradlew
  cd "$target/$repo_name" || { err "进入目录失败"; return 1; }
  ok "已进入 $(pwd)"
  ensure_gradle_wrapper || true
  
  # 进入构建菜单
  build_menu "$PWD"
}

# -------------------------
# 选择现有项目
# -------------------------
choose_existing_project(){
  load_config
  ensure_dir "$PROJECT_BASE"
  
  # 列出项目目录
  local dirs=()
  shopt -s nullglob
  for d in "$PROJECT_BASE"/*/; do 
    dirs+=("$d")
  done
  shopt -u nullglob
  
  if [[ ${#dirs[@]} -eq 0 ]]; then 
    warn "未找到项目在 $PROJECT_BASE"
    return 1
  fi
  
  # 选择项目
  echo "请选择项目："
  select p in "${dirs[@]}" "取消"; do
    if [[ "$p" == "取消" || -z "$p" ]]; then 
      return 1
    else 
      ok "已选择项目: $p"
      build_menu "$p"
      break
    fi
  done
}

# -------------------------
# 模组类型/版本检测
# -------------------------
detect_mod_type(){
  local dir="$1"
  if [[ -f "$dir/fabric.mod.json" ]] || grep -qi "fabric-loom" "$dir"/build.gradle* 2>/dev/null; then 
    echo "fabric"
  elif grep -qi "minecraftforge" "$dir"/build.gradle* 2>/dev/null || [[ -f "$dir/src/main/resources/META-INF/mods.toml" ]]; then 
    echo "forge"
  elif [[ -d "$dir/mcp" || -f "$dir/conf/joined.srg" || -f "$dir/setup.sh" ]]; then 
    echo "mcp"
  elif [[ -f "$dir/pom.xml" ]]; then 
    echo "maven"
  elif [[ -f "$dir/build.gradle" || -f "$dir/gradlew" ]]; then 
    echo "gradle"
  else 
    echo "unknown"
  fi
}

detect_mc_version(){
  local dir="$1"; local ver=""
  if [[ -f "$dir/gradle.properties" ]]; then
    ver=$(grep -E "minecraft_version|mc_version" "$dir/gradle.properties" 2>/dev/null | head -n1 | cut -d= -f2 | sed 's/ //g')
  fi
  if [[ -z "$ver" && -f "$dir/fabric.mod.json" ]]; then
    ver=$(grep -o '"minecraft": *"[^"]*"' "$dir/fabric.mod.json" | head -n1 | cut -d\" -f4 | sed 's/ //g')
  fi
  echo "${ver:-unknown}"
}

has_gradle_task(){
  local dir="$1"; local task="$2"
  (cd "$dir" && ./gradlew tasks --all 2>/dev/null | grep -q "$task")
}

# -------------------------
# 查找构建产物 & 发布
# -------------------------
find_final_jar(){
  local dir="$1"; local type="$2"; local res=""
  
  # 按模组类型查找产物
  if [[ "$type" == "fabric" || "$type" == "quilt" ]]; then
    res=$(find "$dir/build" -type f \( -iname "*remapped*.jar" -o -iname "*mapped*.jar" \) 2>/dev/null | head -n1)
    [[ -z "$res" ]] && res=$(find "$dir/build" -type f -iname "*.jar" ! -iname "*dev*" ! -iname "*sources*" 2>/dev/null | head -n1)
  elif [[ "$type" == "forge" ]]; then
    res=$(find "$dir/build" -type f -iname "*reobf*.jar" 2>/dev/null | head -n1)
    [[ -z "$res" ]] && res=$(find "$dir/build" -type f -iname "*jarjar*.jar" 2>/dev/null | head -n1)
    [[ -z "$res" ]] && res=$(find "$dir/build" -type f -iname "*.jar" ! -iname "*sources*" 2>/dev/null | head -n1)
  else
    res=$(find "$dir/build" -type f -iname "*.jar" ! -iname "*sources*" ! -iname "*dev*" 2>/dev/null | head -n1)
  fi
  
  echo "$res"
}

publish_release(){
  local dir="$1"; local jar="$2"
  if [[ -z "$jar" || ! -f "$jar" ]]; then
    err "Jar 文件不存在: $jar"
    return 1
  fi
  
  # 复制到本地release目录
  ensure_dir "$dir/release"
  cp -f "$jar" "$dir/release/"
  ok "已复制到: $dir/release/$(basename "$jar")"
  
  # 复制到SD卡（Termux）
  if [[ -d "/sdcard" || -d "$HOME/storage/shared" ]]; then
    ensure_dir "$SDCARD_DOWNLOAD" 2>/dev/null || true
    cp -f "$jar" "$SDCARD_DOWNLOAD/" 2>/dev/null || warn "无法复制到 SD 卡: $SDCARD_DOWNLOAD"
    ok "已尝试复制到: $SDCARD_DOWNLOAD/$(basename "$jar")"
  fi
}

# -------------------------
# 构建失败诊断
# -------------------------
diagnose_build_failure(){
  local log="$1"
  if [[ ! -f "$log" ]]; then
    warn "日志文件不存在: $log"
    return 1
  fi
  
  warn "诊断构建失败 (查看 $log) ..."
  if grep -qi "OutOfMemoryError" "$log" 2>/dev/null; then 
    echo "- 可能: 内存不足。建议: 增加 Gradle 堆内存，或清理缓存"
  fi
  if grep -qi "Could not resolve" "$log" 2>/dev/null; then 
    echo "- 可能: 依赖下载失败(网络/镜像)"
  fi
  if grep -qi "Unsupported major.minor version" "$log" 2>/dev/null; then 
    echo "- 可能: Java 版本不匹配(例如需要 Java 17)"
  fi
  echo "- 常用修复: ./gradlew clean --no-daemon ; ./gradlew build --stacktrace"
}

# -------------------------
# 混淆功能 (基础/进阶)
# -------------------------
obfuscate_basic(){
  local dir="$1"
  local jar="$2"
  ensure_proguard || { err "ProGuard 未就绪"; return 1; }
  
  if [[ -z "$jar" || ! -f "$jar" ]]; then
    err "Jar 文件不存在: $jar"
    return 1
  fi
  
  local out="${jar%.jar}-obf.jar"
  info "ProGuard 混淆 -> $(basename "$out")"
  
  # 执行ProGuard混淆
  if java -jar "$PROGUARD_JAR" \
       -injars "$jar" \
       -outjars "$out" \
       -dontwarn \
       -dontoptimize \
       -dontshrink \
       '-keep public class * { public protected *; }'; then
    ok "ProGuard 混淆成功: $(basename "$out")"
    ensure_dir "$dir/release"
    cp -f "$out" "$dir/release/"
    return 0
  else
    err "ProGuard 混淆失败"
    return 1
  fi
}

inject_antidebug_into_jar(){
  local target="$1"
  if [[ -z "$target" || ! -f "$target" ]]; then
    err "目标 Jar 不存在: $target"
    return 1
  fi
  
  # 创建临时目录
  local tmpd=$(mktemp -d)
  
  # 编写反调试代码
  cat > "$tmpd/AntiDebug.java" <<'JAVA'
public class AntiDebug {
  static {
    try {
      if (java.lang.management.ManagementFactory.getRuntimeMXBean().getInputArguments().toString().contains("-agentlib:jdwp")) {
        throw new RuntimeException("Debug not allowed");
      }
    } catch (Throwable t) {}
  }
  public static void init() {}
}
JAVA
  
  # 编译并注入
  (cd "$tmpd" && javac AntiDebug.java 2>/dev/null) || { 
    warn "javac 不可用，跳过注入"
    rm -rf "$tmpd"
    return 1
  }
  (cd "$tmpd" && jar uf "$target" AntiDebug.class) 2>/dev/null || { 
    warn "jar 更新失败，跳过"
    rm -rf "$tmpd"
    return 1
  }
  
  # 清理临时文件
  rm -rf "$tmpd"
  ok "已向 $target 注入 AntiDebug"
  return 0
}

obfuscate_advanced(){
  local dir="$1"
  local jar="$2"
  
  if [[ -z "$jar" || ! -f "$jar" ]]; then
    err "Jar 文件不存在: $jar"
    return 1
  fi
  
  # 基础混淆
  obfuscate_basic "$dir" "$jar" || { err "基础混淆失败"; return 1; }
  local obf="${jar%.jar}-obf.jar"
  local secure="${jar%.jar}-secure.jar"
  
  # 字符串加密（可选）
  if [[ -f "$STRINGER_JAR" ]]; then
    info "使用 stringer.jar 进行字符串加密..."
    if java -jar "$STRINGER_JAR" --input "$obf" --output "$secure" --mode xor 2>&1 | sed 's/^/    /'; then
      ok "字符串加密完成"
    else
      warn "stringer 失败，使用原始混淆文件"
      cp -f "$obf" "$secure"
    fi
  else
    warn "未检测到 stringer.jar (放在 ~/stringer.jar 可自动使用)"
    cp -f "$obf" "$secure"
  fi
  
  # 注入反调试
  inject_antidebug_into_jar "$secure" || warn "注入 anti-debug 失败"
  
  # 发布产物
  ensure_dir "$dir/release"
  cp -f "$secure" "$dir/release/"
  ok "进阶混淆完成 -> $(basename "$secure")"
  return 0
}

secure_pipeline(){
  local dir="$1"; local jar="$2"
  obfuscate_advanced "$dir" "$jar" || { err "进阶混淆失败"; return 1; }
  ok "Secure pipeline 完成"
  return 0
}

# -------------------------
# ZKM 反混淆 (单文件/批量)
# -------------------------
zkm_deobf_single(){
  ensure_zkm || { err "ZKM 未就绪"; return 1; }
  local input="$1"
  
  if [[ -z "$input" || ! -f "$input" ]]; then
    err "输入 Jar 不存在: $input"
    return 1
  fi
  
  ensure_dir "$BASE/release/deobf"
  
  # 选择转换器
  echo "Transformer: 1) s11 2) si11 3) rvm11 4) cf11 5) all"
  read -p "选择 (1-5, default 5): " t; t=${t:-5}
  
  case "$t" in 
    1) trans="s11" ;; 
    2) trans="si11" ;; 
    3) trans="rvm11" ;; 
    4) trans="cf11" ;; 
    5) trans="s11,si11,rvm11,cf11" ;; 
    *) trans="s11,si11,rvm11,cf11" ;; 
  esac
  
  # 执行反混淆
  out="$BASE/release/deobf/$(basename "$input" .jar)-deobf.jar"
  info "运行 ZKM ($trans) -> $out"
  
  if java -jar "$ZKM_JAR" --input "$input" --output "$out" --transformer "$trans" --verbose; then
    ok "ZKM 完成 -> $out"
  else
    err "ZKM 执行失败"
    return 1
  fi
}

batch_zkm_deobf(){
  ensure_zkm || { err "ZKM 未就绪"; return 1; }
  ensure_dir "$BASE/release/deobf"
  
  # 输入目录
  read -p "输入包含 Jar 文件的目录: " jar_dir
  if [[ -z "$jar_dir" || ! -d "$jar_dir" ]]; then
    err "目录不存在: $jar_dir"
    return 1
  fi
  
  # 选择转换器
  echo "Transformer: 1) s11 2) si11 3) rvm11 4) cf11 5) all"
  read -p "选择 (1-5, default 5): " t; t=${t:-5}
  
  case "$t" in 
    1) trans="s11" ;; 
    2) trans="si11" ;; 
    3) trans="rvm11" ;; 
    4) trans="cf11" ;; 
    5) trans="s11,si11,rvm11,cf11" ;; 
    *) trans="s11,si11,rvm11,cf11" ;; 
  esac

  # 批量处理
  find "$jar_dir" -type f -iname "*.jar" ! -iname "*-deobf.jar" | while read -r jar; do
    if [[ -f "$jar" ]]; then
      out="$BASE/release/deobf/$(basename "$jar" .jar)-deobf.jar"
      info "处理: $(basename "$jar") -> $(basename "$out")"
      if java -jar "$ZKM_JAR" --input "$jar" --output "$out" --transformer "$trans" --verbose; then
        ok "ZKM 完成: $(basename "$out")"
      else
        err "ZKM 处理失败: $(basename "$jar")"
      fi
    fi
  done
  
  ok "批量 ZKM 反混淆完成"
}

# -------------------------
# 核心构建菜单 (build_menu)
# -------------------------
build_menu(){
  local dir="$1"
  [[ -z "$dir" || ! -d "$dir" ]] && { err "无效的项目目录: $dir"; return 1; }
  
  local original_pwd="$PWD"
  cd "$dir" || { err "无法进入目录 $dir"; return 1; }

  # 检测项目信息
  local mod_type=$(detect_mod_type "$dir")
  local mc_ver=$(detect_mc_version "$dir")
  local build_log="$dir/build_mcdev.log"
  
  # 菜单头部
  clear
  info "=== Minecraft Mod 构建菜单 ==="
  info "项目路径: $dir"
  info "模组类型: $mod_type | MC版本: $mc_ver"
  echo "----------------------------------------"

  while true; do
    # 展示菜单选项
    echo -e "\n请选择操作："
    echo "  1) 清理项目 (clean)"
    echo "  2) 构建项目 (build) [生成JAR]"
    echo "  3) 查找构建产物 (find JAR)"
    echo "  4) 发布产物 (复制到release/SD卡)"
    echo "  5) 基础混淆 (ProGuard)"
    echo "  6) 进阶混淆 (ProGuard+字符串加密+反调试)"
    echo "  7) ZKM反混淆 (单文件)"
    echo "  8) 批量ZKM反混淆"
    echo "  9) 诊断构建失败"
    echo "  10) 重新检测项目信息"
    echo "  11) 优化Gradle配置"
    echo "  0) 返回上级菜单"
    read -p "输入选择 [0-11]: " choice
    echo "----------------------------------------"

    # 菜单逻辑
    case "$choice" in
      1) # 清理项目
        info "执行 ./gradlew clean ..."
        run_and_log "$build_log" ./gradlew clean --no-daemon
        [[ $? -eq 0 ]] && ok "项目清理完成" || err "清理失败，日志: $build_log"
        ;;

      2) # 构建项目
        info "执行构建 (mod_type: $mod_type) ..."
        local build_task="build"
        
        # 适配不同模组类型的构建任务
        if [[ "$mod_type" == "fabric" && has_gradle_task "$dir" "remapJar" ]]; then
          build_task="remapJar"
        elif [[ "$mod_type" == "forge" && has_gradle_task "$dir" "build" ]]; then
          build_task="build"
        elif [[ "$mod_type" == "maven" ]]; then
          build_task="package"
        fi

        info "使用任务: $build_task"
        run_and_log "$build_log" ./gradlew "$build_task" --no-daemon
        
        if [[ $? -eq 0 ]]; then
          ok "构建成功！"
          local jar=$(find_final_jar "$dir" "$mod_type")
          [[ -n "$jar" ]] && info "找到产物: $jar"
        else
          err "构建失败，日志: $build_log"
          read -p "是否立即诊断失败原因？(y/N): " diag
          [[ "$diag" =~ ^[Yy]$ ]] && diagnose_build_failure "$build_log"
        fi
        ;;

      3) # 查找构建产物
        local jar=$(find_final_jar "$dir" "$mod_type")
        if [[ -n "$jar" && -f "$jar" ]]; then
          ok "找到构建产物:"
          ls -lh "$jar"
        else
          warn "未找到有效JAR文件，请先执行构建"
        fi
        ;;

      4) # 发布产物
        local jar=$(find_final_jar "$dir" "$mod_type")
        [[ -n "$jar" && -f "$jar" ]] && publish_release "$dir" "$jar" || err "未找到可发布的JAR文件"
        ;;

      5) # 基础混淆
        local jar=$(find_final_jar "$dir" "$mod_type")
        [[ -n "$jar" && -f "$jar" ]] && obfuscate_basic "$dir" "$jar" || err "未找到可混淆的JAR文件"
        ;;

      6) # 进阶混淆
        local jar=$(find_final_jar "$dir" "$mod_type")
        [[ -n "$jar" && -f "$jar" ]] && obfuscate_advanced "$dir" "$jar" || err "未找到可混淆的JAR文件"
        ;;

      7) # ZKM反混淆（单文件）
        local jar=$(find_final_jar "$dir" "$mod_type")
        if [[ -n "$jar" && -f "$jar" ]]; then
          zkm_deobf_single "$jar"
        else
          read -p "未自动找到JAR，请输入JAR文件路径: " custom_jar
          [[ -f "$custom_jar" ]] && zkm_deobf_single "$custom_jar" || err "文件不存在: $custom_jar"
        fi
        ;;

      8) # 批量ZKM反混淆
        read -p "输入包含JAR的目录路径: " jar_dir
        if [[ -d "$jar_dir" ]]; then
          local jar_list=($(find "$jar_dir" -type f -iname "*.jar" ! -iname "*sources*" ! -iname "*dev*"))
          if [[ ${#jar_list[@]} -eq 0 ]]; then
            warn "目录中未找到有效JAR文件: $jar_dir"
            continue
          fi
          info "找到 ${#jar_list[@]} 个JAR文件，开始批量反混淆..."
          for jar in "${jar_list[@]}"; do
            info "处理: $jar"
            zkm_deobf_single "$jar"
            sleep 1
          done
          ok "批量ZKM反混淆完成"
        else
          err "无效的目录: $jar_dir"
        fi
        ;;

      9) # 诊断构建失败
        if [[ -f "$build_log" ]]; then
          diagnose_build_failure "$build_log"
        else
          warn "未找到构建日志: $build_log"
          read -p "是否指定其他日志文件？(y/N): " log_path
          if [[ "$log_path" =~ ^[Yy]$ ]]; then
            read -p "输入日志路径: " custom_log
            [[ -f "$custom_log" ]] && diagnose_build_failure "$custom_log" || err "日志文件不存在: $custom_log"
          fi
        fi
        ;;

      10) # 重新检测项目信息
        mod_type=$(detect_mod_type "$dir")
        mc_ver=$(detect_mc_version "$dir")
        ok "重新检测完成:"
        echo "  模组类型: $mod_type"
        echo "  MC版本: $mc_ver"
        ;;

      11) # 优化Gradle配置
        configure_gradle_optimization
        ;;

      0) # 返回上级
        info "退出构建菜单，返回上级..."
        cd "$original_pwd" || true
        return 0
        ;;

      *) # 无效选择
        warn "无效的选择，请输入 0-11 之间的数字"
        ;;
    esac
    
    # 操作后暂停
    echo "----------------------------------------"
    read -p "按Enter键继续..."
    clear
  done
}

# -------------------------
# 主菜单 (脚本入口)
# -------------------------
main_menu(){
  load_config
  check_storage_and_hint
  ensure_basic_tools

  while true; do
    clear
    echo -e "${CYAN}=== Minecraft Mod 构建流水线 (Termux 兼容) ===${RESET}"
    echo "1) 安装基础依赖 & JDK"
    echo "2) 克隆 Mod 仓库"
    echo "3) 选择现有 Mod 项目"
    echo "4) 安装 Gradle (从 ZIP/URL)"
    echo "5) 配置 Gradle 优化 (镜像/内存)"
    echo "6) 安装 ProGuard/CFR/ZKM 工具"
    echo "7) ZKM 单文件反混淆"
    echo "8) ZKM 批量反混淆"
    echo "9) 退出"
    read -p "选择操作 [1-9]: " opt

    case "$opt" in
      1)
        ensure_basic_tools
        auto_install_jdk
        ensure_maven
        ok "基础环境配置完成"
        ;;
      2)
        clone_repo
        ;;
      3)
        choose_existing_project
        ;;
      4)
        install_gradle_from_zip
        ;;
      5)
        configure_gradle_optimization
        ;;
      6)
        ensure_proguard
        ensure_cfr
        ensure_zkm
        ok "工具安装/检查完成"
        ;;
      7)
        read -p "输入 Jar 文件路径: " jar_path
        zkm_deobf_single "$jar_path"
        ;;
      8)
        batch_zkm_deobf
        ;;
      9)
        ok "退出脚本"
        exit 0
        ;;
      *)
        warn "无效选择，请重新输入"
        sleep 1
        ;;
    esac
    
    read -p "按任意键返回主菜单..." -n1
  done
}

# 脚本入口
main_menu
