#!/usr/bin/env bash
# mcdev_final.sh
# Ultimate single-file Minecraft Mod pipeline (Termux-friendly)
#  - Full integration: JDK (custom + auto download), Gradle wrapper, Gradle ZIP import,
#    Maven, Gradle optimization, Git clone with proxy, Fabric/Forge/MCP detection,
#    remap/reobf handling, release publishing, ProGuard, advanced obf, ZKM, CFR,
#    Fabric/Forge MDK download, batch build, full pipeline.
#
# Usage:
#   chmod +x mcdev_final.sh
#   ./mcdev_final.sh
#
# IMPORTANT: Use third-party deobfuscation tools (ZKM) only for legal/ethical purposes.

set -euo pipefail
IFS=$'\n\t'

# -------------------------
# Colors & helpers
# -------------------------
RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; BLUE="\033[1;34m"; CYAN="\033[1;36m"; RESET="\033[0m"
info(){ echo -e "${BLUE}[INFO]${RESET} $*"; }
ok(){ echo -e "${GREEN}[OK]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
err(){ echo -e "${RED}[ERR]${RESET} $*"; }

# -------------------------
# Paths & globals
# -------------------------
BASE="$HOME/modpipeline"
PROJECTS_LOCAL="$HOME/projects"
PROJECTS_SDCARD="$HOME/storage/shared/Projects"   # Termux shared path
TOOLS_DIR="$BASE/tools"
PROGUARD_DIR="$TOOLS_DIR/proguard"
PROGUARD_JAR="$PROGUARD_DIR/proguard.jar"
ZKM_DIR="$TOOLS_DIR/zelixkiller"
ZKM_JAR="$ZKM_DIR/zkm.jar"
CFR_DIR="$TOOLS_DIR/cfr"
CFR_JAR="$CFR_DIR/cfr.jar"
STRINGER_JAR="$HOME/stringer.jar"   # optional external string obfuscator
CONFIG_FILE="$HOME/.mcdev_env.conf"
GRADLE_USER_HOME="$HOME/.gradle"
SDCARD_DOWNLOAD="/sdcard/Download"
ARCH=$(uname -m)

IS_TERMUX=false
PKG_INSTALL_CMD=""

# Determine environment & package manager
if command -v pkg >/dev/null 2>&1; then
  IS_TERMUX=true
  PKG_INSTALL_CMD="pkg install -y"
elif command -v apt >/dev/null 2>&1; then
  PKG_INSTALL_CMD="sudo apt-get install -y"
elif command -v yum >/dev/null 2>&1; then
  PKG_INSTALL_CMD="sudo yum install -y"
fi

# -------------------------
# Utility
# -------------------------
ensure_dir(){ mkdir -p "$1"; }
run_and_log(){ local log="$1"; shift; "$@" 2>&1 | tee "$log"; return "${PIPESTATUS[0]}"; }

# -------------------------
# Config load/save
# -------------------------
load_config(){
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  fi
  if [[ -z "${PROJECT_BASE:-}" ]]; then
    if [[ -d "$PROJECTS_SDCARD" ]]; then PROJECT_BASE="$PROJECTS_SDCARD"; else PROJECT_BASE="$PROJECTS_LOCAL"; fi
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
# Storage / Termux helper
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
# Ensure basic CLI tools
# -------------------------
ensure_basic_tools(){
  local need=(git wget curl unzip zip tar sed awk javac)
  local miss=()
  for t in "${need[@]}"; do
    if ! command -v "$t" >/dev/null 2>&1; then miss+=("$t"); fi
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
# JDK: auto download and custom install
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
  api_url="https://api.adoptium.net/v3/binary/latest/${ver}/ga/linux/${arch_dl}/jdk/hotspot/normal/eclipse"
  info "将通过 Adoptium API 下载 JDK $ver ..."
  tmp="/tmp/jdk${ver}.tar.gz"
  if wget -O "$tmp" "$api_url"; then
    info "下载完成，正在解压..."
    tar -xzf "$tmp" -C "$dest" --strip-components=1 || { err "解压失败"; return 1; }
    rm -f "$tmp"
    shell_rc="$HOME/.bashrc"; [[ -n "${ZSH_VERSION-}" ]] && shell_rc="$HOME/.zshrc"
    if ! grep -q "mcdev jdk $ver" "$shell_rc" 2>/dev/null; then
      {
        echo ""
        echo "# mcdev jdk $ver"
        echo "export JAVA_HOME=\"$dest\""
        echo 'export PATH=$JAVA_HOME/bin:$PATH'
      } >> "$shell_rc"
      ok "已写入 $shell_rc（重新打开 shell 或 source 生效）"
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
  if [[ "$src" =~ ^https?:// ]]; then
    tmp="/tmp/custom_jdk_$(date +%s).tar.gz"
    info "下载自定义 JDK..."
    if ! wget -O "$tmp" "$src"; then err "下载失败"; return 1; fi
    src="$tmp"
  fi
  if [[ ! -f "$src" ]]; then err "文件不存在: $src"; return 1; fi
  dest="$HOME/jdk-custom-$(date +%s)"
  ensure_dir "$dest"
  info "解压到 $dest ..."
  case "$src" in
    *.tar.gz|*.tgz) tar -xzf "$src" -C "$dest" --strip-components=1 ;;
    *.zip) unzip -q "$src" -d "$dest" ;;
    *) err "不支持的压缩格式"; return 1 ;;
  esac
  shell_rc="$HOME/.bashrc"; [[ -n "${ZSH_VERSION-}" ]] && shell_rc="$HOME/.zshrc"
  {
    echo ""
    echo "# mcdev custom jdk"
    echo "export JAVA_HOME=\"$dest\""
    echo 'export PATH=$JAVA_HOME/bin:$PATH'
  } >> "$shell_rc"
  export JAVA_HOME="$dest"; export PATH="$JAVA_HOME/bin:$PATH"
  ok "自定义 JDK 已安装并写入 $shell_rc"
  return 0
}

# -------------------------
# ProGuard auto-download
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
# ZKM (ZelixKiller) auto-download (user-provided URL default)
# -------------------------
ensure_zkm(){
  if [[ -f "$ZKM_JAR" ]]; then ok "ZKM 就绪"; return 0; fi
  ensure_dir "$ZKM_DIR"
  ZKM_URL_DEFAULT="https://raw.githubusercontent.com/fkbmr/sb/main/zkm.jar"
  read -p "请输入 ZKM 下载 URL (回车使用默认): " zurl
  zurl=${zurl:-$ZKM_URL_DEFAULT}
  info "下载 ZKM..."
  if wget -O "$ZKM_JAR" "$zurl"; then ok "ZKM 已下载: $ZKM_JAR"; return 0; else err "ZKM 下载失败"; return 1; fi
}

# -------------------------
# CFR ensure (decompiler)
# -------------------------
ensure_cfr(){
  if [[ -f "$CFR_JAR" ]]; then ok "CFR 就绪"; return 0; fi
  ensure_dir "$CFR_DIR"
  CFR_URL="https://www.benf.org/other/cfr/cfr-0.152.jar"
  info "下载 CFR..."
  if wget -O "$CFR_JAR" "$CFR_URL"; then ok "CFR 已下载"; return 0; else err "CFR 下载失败"; return 1; fi
}

# -------------------------
# Gradle wrapper / install
# -------------------------
ensure_gradle_wrapper(){
  if [[ -f "./gradlew" ]]; then chmod +x ./gradlew 2>/dev/null || true; ok "gradlew 已存在"; return 0; fi
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
  if [[ "$zippath" =~ ^https?:// ]]; then
    tmp="/tmp/gradle_$(date +%s).zip"
    info "下载 Gradle ZIP..."
    wget -O "$tmp" "$zippath" || { err "下载失败"; return 1; }
    zippath="$tmp"
  fi
  if [[ ! -f "$zippath" ]]; then err "文件不存在: $zippath"; return 1; fi
  if [[ -w /opt ]]; then dest="/opt/gradle"; else dest="$HOME/.local/gradle"; fi
  ensure_dir "$dest"
  unzip -q -o "$zippath" -d "$dest"
  folder=$(ls "$dest" | head -n1)
  if [[ -x "$dest/$folder/bin/gradle" ]]; then
    ln -sf "$dest/$folder/bin/gradle" /usr/local/bin/gradle 2>/dev/null || ln -sf "$dest/$folder/bin/gradle" "$HOME/.local/bin/gradle"
    ok "Gradle 已安装到 $dest/$folder"
    return 0
  fi
  err "Gradle 安装后未找到 bin/gradle"
  return 1
}

# -------------------------
# Maven ensure
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
# Gradle optimization & init (mirrors)
# -------------------------
configure_gradle_optimization(){
  ensure_dir "$GRADLE_USER_HOME"
  PROPS="$GRADLE_USER_HOME/gradle.properties"
  if [[ -f /proc/meminfo ]]; then
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    mem_mb=$((mem_kb/1024))
  else mem_mb=2048; fi
  xmx=$((mem_mb*70/100))
  (( xmx > 4096 )) && xmx=4096
  sed -i '/org.gradle.jvmargs/d' "$PROPS" 2>/dev/null || true
  echo "org.gradle.jvmargs=-Xmx${xmx}m -Dfile.encoding=UTF-8" >> "$PROPS"
  ok "写入 $PROPS (-Xmx ${xmx}m)"
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
  ok "写入 Gradle init (镜像)"
}

# -------------------------
# Git clone (proxy options) and place selection
# -------------------------
clone_repo(){
  read -p "仓库 (user/repo 或 完整 URL): " repo_input
  [[ -z "$repo_input" ]] && { warn "取消"; return 1; }
  if [[ "$repo_input" =~ ^https?:// ]]; then repo_url="$repo_input"; else
    echo "是否使用镜像加速?"
    echo "1) gh-proxy.org   2) ghproxy.com   3) hub.fastgit.xyz   4) 自定义   5) 不使用"
    read -p "选择 [1-5]: " proxy
    case "$proxy" in
      1) base="https://gh-proxy.org/https://github.com/" ;;
      2) base="https://ghproxy.com/https://github.com/" ;;
      3) base="https://hub.fastgit.xyz/https://github.com/" ;;
      4) read -p "输入镜像前缀 (例如 https://myproxy/https://github.com/): " custom; base="$custom" ;;
      *) base="https://github.com/" ;;
    esac
    repo_url="${base}${repo_input}.git"
  fi

  load_config
  echo "选择存放位置 (默认: $PROJECT_BASE):"
  echo "1) 本地: $PROJECTS_LOCAL"
  if [[ "$IS_TERMUX" == "true" ]]; then echo "2) 共享: $PROJECTS_SDCARD"; fi
  echo "3) 自定义路径"
  read -p "选择 [Enter=默认]: " choice
  case "$choice" in
    2) target="$PROJECTS_SDCARD" ;;
    3) read -p "输入目标路径: " customp; target="$customp" ;;
    *) target="$PROJECTS_LOCAL" ;;
  esac
  ensure_dir "$target"
  save_config
  info "克隆到: $target"
  git clone "$repo_url" "$target/$(basename "$repo_input" .git)" || { err "git clone 失败"; return 1; }
  ok "克隆完成"
  cd "$target/$(basename "$repo_input" .git)" || return 0
  ok "已进入 $(pwd)"
  ensure_gradle_wrapper || true
  build_menu "$PWD"
}

# -------------------------
# Choose existing project
# -------------------------
choose_existing_project(){
  load_config
  ensure_dir "$PROJECT_BASE"
  local dirs=()
  for d in "$PROJECT_BASE"/*; do [[ -d "$d" ]] && dirs+=("$d"); done
  if [[ ${#dirs[@]} -eq 0 ]]; then warn "未找到项目在 $PROJECT_BASE"; return 1; fi
  echo "请选择项目："
  select p in "${dirs[@]}" "取消"; do
    if [[ "$p" == "取消" || -z "$p" ]]; then return 1; else build_menu "$p"; break; fi
  done
}

# -------------------------
# Detect mod type / mc version / gradle task
# -------------------------
detect_mod_type(){
  local dir="$1"
  if [[ -f "$dir/fabric.mod.json" ]] || grep -qi "fabric-loom" "$dir"/build.gradle* 2>/dev/null; then echo "fabric"
  elif grep -qi "minecraftforge" "$dir"/build.gradle* 2>/dev/null || [[ -f "$dir/src/main/resources/META-INF/mods.toml" ]]; then echo "forge"
  elif [[ -d "$dir/mcp" || -f "$dir/conf/joined.srg" || -f "$dir/setup.sh" ]]; then echo "mcp"
  elif [[ -f "$dir/pom.xml" ]]; then echo "maven"
  elif [[ -f "$dir/build.gradle" || -f "$dir/gradlew" ]]; then echo "gradle"
  else echo "unknown"; fi
}

detect_mc_version(){
  local dir="$1"; local ver=""
  [[ -f "$dir/gradle.properties" ]] && ver=$(grep -E "minecraft_version|mc_version" "$dir/gradle.properties" 2>/dev/null | head -n1 | cut -d= -f2)
  [[ -z "$ver" && -f "$dir/fabric.mod.json" ]] && ver=$(grep -o '"minecraft": *"[^"]*"' "$dir/fabric.mod.json" | head -n1 | cut -d\" -f4)
  echo "${ver:-unknown}"
}

has_gradle_task(){
  local dir="$1"; local task="$2"
  (cd "$dir" && ./gradlew tasks --all 2>/dev/null | grep -q "$task")
}

# -------------------------
# Find final jar & publish
# -------------------------
find_final_jar(){
  local dir="$1"; local type="$2"; local res=""
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
  ensure_dir "$dir/release"
  cp -f "$jar" "$dir/release/"
  ok "已复制到: $dir/release/$(basename "$jar")"
  if [[ -d "/sdcard" || -d "$HOME/storage/shared" ]]; then
    mkdir -p "$SDCARD_DOWNLOAD" 2>/dev/null || true
    cp -f "$jar" "$SDCARD_DOWNLOAD/" 2>/dev/null || true
    ok "已尝试复制到: $SDCARD_DOWNLOAD/$(basename "$jar")"
  fi
}

# -------------------------
# Diagnose build failure
# -------------------------
diagnose_build_failure(){
  local log="$1"
  warn "诊断构建失败 (查看 $log) ..."
  if grep -qi "OutOfMemoryError" "$log" 2>/dev/null; then echo "- 可能: 内存不足。建议: 增加 Gradle 堆内存，或清理缓存"; fi
  if grep -qi "Could not resolve" "$log" 2>/dev/null; then echo "- 可能: 依赖下载失败(网络/镜像)"; fi
  if grep -qi "Unsupported major.minor version" "$log" 2>/dev/null; then echo "- 可能: Java 版本不匹配(例如需要 Java 17)"; fi
  echo "- 常用修复: ./gradlew clean --no-daemon ; ./gradlew build --stacktrace"
}

# -------------------------
# Obfuscation: ProGuard (basic)
# -------------------------
#obfuscate_basic(){
  #local dir="$1"; local jar="$2"
 # ensure_proguard || { err "ProGuard 未就绪"; return 1; }
  #local out="${jar%.jar}-obf.jar"
  #info "ProGuard 混淆 -> $(basename "$out")"
  #java -jar "$PROGUARD_JAR" -injars "$jar" -outjars "$out" -dontwarn -dontoptimize -dontshrink -keep public class * { public protected *; }
  #if [[ $? -eq 0 ]]; then
    #ok "ProGuard 混淆成功: $(basename "$out")"
    #cp -f "$out" "$(dirname "$jar")/../release/"
    #return 0
  #else
    #err "ProGuard 混淆失败"
    #return 1
#  fi
#}

# -------------------------
# Advanced obfuscation: string tool + anti-debug injection
# -------------------------
inject_antidebug_into_jar(){
  local target="$1"
  local tmpd
  tmpd=$(mktemp -d)
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
  (cd "$tmpd" && javac AntiDebug.java 2>/dev/null) || { warn "javac 不可用，跳过注入"; rm -rf "$tmpd"; return 1; }
  (cd "$tmpd" && jar uf "$target" AntiDebug.class) 2>/dev/null || { warn "jar 更新失败，跳过"; rm -rf "$tmpd"; return 1; }
  rm -rf "$tmpd"
  ok "已向 $target 注入 AntiDebug"
  return 0
}

obfuscate_advanced(){
  local dir="$1"; local jar="$2"
  obfuscate_basic "$dir" "$jar" || { err "基础混淆失败"; return 1; }
  local obf="${jar%.jar}-obf.jar"
  local secure="${jar%.jar}-secure.jar"
  if [[ -f "$STRINGER_JAR" ]]; then
    info "使用 stringer.jar 进行字符串加密..."
    java -jar "$STRINGER_JAR" --input "$obf" --output "$secure" --mode xor 2>&1 | sed 's/^/    /'
    [[ $? -ne 0 ]] && warn "stringer 失败，使用 obf"
  else
    warn "未检测到 stringer.jar (放在 ~/stringer.jar 可被自动使用)"
    cp -f "$obf" "$secure"
  fi
  inject_antidebug_into_jar "$secure" || warn "注入 anti-debug 失败"
  cp -f "$secure" "$(dirname "$jar")/../release/"
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
# ZKM deobfuscation single & batch
# -------------------------
zkm_deobf_single(){
  ensure_zkm || { err "ZKM 未就绪"; return 1; }
  local input="$1"
  [[ ! -f "$input" ]] && { err "输入 Jar 不存在: $input"; return 1; }
  ensure_dir "$BASE/release/deobf"
  echo "Transformer: 1) s11 2) si11 3) rvm11 4) cf11 5) all"
  read -p "选择 (1-5, default 5): " t; t=${t:-5}
  case "$t" in 1) trans="s11" ;; 2) trans="si11" ;; 3) trans="rvm11" ;; 4) trans="cf11" ;; 5) trans="s11,si11,rvm11,cf11" ;; *) trans="s11,si11,rvm11,cf11" ;; esac
  out="$BASE/release/deobf/$(basename "$input" .jar)-deobf.jar"
  info "运行 ZKM ($trans) -> $out"
  java -jar "$ZKM_JAR" --input "$input" --output "$out" --transformer "$trans" --verbose
  if [[ $? -eq 0 ]]; then ok "ZKM 完成 -> $out"; else err "ZKM 执行失败"; fi
}

batch_zkm_deobf(){
  ensure_zkm || { err "ZKM 未就绪"; return 1; }
  ensure_dir "$BASE/release/deobf"
  for jar in "$BASE"/release/*.jar; do
    [[ -f "$jar" ]] || continue
    out="$BASE/release/deobf/$(basename "$jar" .jar)-deobf.jar"
    info "ZKM 处理 $(basename "$jar") ..."
    java -jar "$ZKM_JAR" --input "$jar" --output "$out" --transformer "s11,si11,rvm11,cf11" --verbose
    ok "ZKM done: $out"
  done
}

# -------------------------
# CFR decompile
# -------------------------
cfr_decompile_single(){
  ensure_cfr || return 1
  local jar="$1"
  [[ ! -f "$jar" ]] && { err "Jar not found: $jar"; return 1; }
  outdir="$BASE/decompile/$(basename "$jar" .jar)"
  ensure_dir "$outdir"
  java -jar "$CFR_JAR" "$jar" --outputdir "$outdir"
  ok "反编译完成 -> $outdir"
}

# -------------------------
# Fabric / Forge MDK download
# -------------------------
download_fabric_mdk(){
  read -p "输入 Minecraft 版本 (例: 1.20.1): " mcver
  [[ -z "$mcver" ]] && { warn "取消"; return 1; }
  dest="$PROJECTS_LOCAL/fabric-$mcver"
  ensure_dir "$dest"
  tmp="/tmp/fabric-example-$mcver.zip"
  info "下载 Fabric example skeleton (可能需要手动调整 mc 版本)"
  wget -q -O "$tmp" "https://github.com/FabricMC/fabric-example-mod/archive/refs/heads/1.20.zip" || { err "下载失败"; return 1; }
  unzip -q "$tmp" -d "$dest"
  mv "$dest"/fabric-example-mod-*/* "$dest"/ 2>/dev/null || true
  rm -f "$tmp"
  ok "Fabric skeleton 已放入 $dest"
}

download_forge_mdk(){
  read -p "输入 Minecraft 版本 (例: 1.20.1): " mcver
  [[ -z "$mcver" ]] && { warn "取消"; return 1; }
  info "尝试获取 Forge 最新 promotion 对应 $mcver (可能需要手动确认)"
  JSON=$(curl -s https://files.minecraftforge.net/maven/net/minecraftforge/forge/promotions_slim.json 2>/dev/null)
  ver=""
  if [[ -n "$JSON" ]]; then ver=$(echo "$JSON" | grep -o "\"$mcver-[^\"]*\"" | head -n1 | tr -d '"'; fi
  if [[ -z "$ver" ]]; then read -p "输入 Forge 完整版本 (如 1.20.1-47.1.0) 或回车取消: " fullv; [[ -z "$fullv" ]] && { warn "取消"; return 1; }; ver="$fullv"; fi
  url="https://maven.minecraftforge.net/net/minecraftforge/forge/${ver}/forge-${ver}-mdk.zip"
  tmp="/tmp/forge-${ver}.zip"
  wget -q -O "$tmp" "$url" || { err "下载失败: $url"; return 1; }
  dest="$PROJECTS_LOCAL/forge-$ver"
  ensure_dir "$dest"
  unzip -q "$tmp" -d "$dest"
  rm -f "$tmp"
  ok "Forge MDK 已解压到 $dest"
}

# -------------------------
# Build menu per project
# -------------------------
build_menu(){
  local dir="$1"
  [[ -z "$dir" ]] && { err "需要项目路径"; return 1; }
  cd "$dir" || return 1
  info "项目: $dir"
  modtype=$(detect_mod_type "$dir")
  mcver=$(detect_mc_version "$dir")
  echo "类型: $modtype   MC: $mcver"
  ensure_gradle_wrapper || true

  echo ""
  echo "1) 智能构建（推荐）"
  echo "2) Clean"
  echo "3) 仅下载依赖"
  echo "4) 生成 Gradle Wrapper"
  echo "5) 构建并发布 release (并选择混淆)"
  echo "6) 返回"
  read -p "选择: " opt
  build_log="/tmp/mcdev_build_$(date +%s).log"
  case "$opt" in
    1)
      if [[ "$modtype" == "fabric" || "$modtype" == "quilt" ]]; then
        if has_gradle_task "$dir" "remapJar"; then run_and_log "$build_log" ./gradlew remapJar --no-daemon --stacktrace; rc=$?; else run_and_log "$build_log" ./gradlew build --no-daemon --stacktrace; rc=$?; fi
      elif [[ "$modtype" == "forge" ]]; then
        run_and_log "$build_log" ./gradlew build --no-daemon --stacktrace; rc=$?; if has_gradle_task "$dir" "reobfJar"; then run_and_log "$build_log" ./gradlew reobfJar --no-daemon --stacktrace; fi
      elif [[ "$modtype" == "maven" ]]; then run_and_log "$build_log" mvn package; rc=$?; else run_and_log "$build_log" ./gradlew build --no-daemon --stacktrace; rc=$?; fi

      if [[ $rc -ne 0 ]]; then err "构建失败, 日志: $build_log"; diagnose_build_failure "$build_log"; return 1; fi
      finaljar=$(find_final_jar "$dir" "$modtype")
      if [[ -n "$finaljar" ]]; then publish_release "$dir" "$finaljar"; else warn "未找到 final jar"; fi
      ;;
    2) run_and_log "$build_log" ./gradlew clean ; ok "Clean 完成" ;;
    3) run_and_log "$build_log" ./gradlew dependencies --no-daemon ; ok "依赖下载完成" ;;
    4) ensure_gradle_wrapper ;;
    5)
      run_and_log "$build_log" ./gradlew build --no-daemon --stacktrace
      rc=$?; if [[ $rc -ne 0 ]]; then err "构建失败"; diagnose_build_failure "$build_log"; return 1; fi
      finaljar=$(find_final_jar "$dir" "$modtype"); [[ -z "$finaljar" ]] && { err "未找到 Jar"; return 1; }
      publish_release "$dir" "$finaljar"
      echo "混淆选项: 1) ProGuard 2) 进阶 3) Secure 4) 不混淆"
      read -p "选择: " mix
      case "$mix" in 1) obfuscate_basic "$dir" "$finaljar" ;; 2) obfuscate_advanced "$dir" "$finaljar" ;; 3) secure_pipeline "$dir" "$finaljar" ;; *) ok "不混淆" ;; esac
      ;;
    *) ok "返回" ;;
  esac
}

# -------------------------
# Batch build all projects
# -------------------------
batch_build_all(){
  load_config
  ensure_dir "$PROJECT_BASE"
  ok "开始批量构建 $PROJECT_BASE 下的项目..."
  success_list=(); fail_list=()
  for d in "$PROJECT_BASE"/*; do
    [[ -d "$d" ]] || continue
    info "构建: $(basename "$d")"
    build_menu "$d" || { warn "项目 $(basename "$d") 失败"; fail_list+=("$(basename "$d")"); continue; }
    success_list+=("$(basename "$d")")
  done
  echo "批量构建完成. 成功: ${success_list[*]}  失败: ${fail_list[*]}"
}

# -------------------------
# Full pipeline for a single project
# -------------------------
full_pipeline_project(){
  local dir="$1"
  [[ -z "$dir" ]] && { err "需指定项目路径"; return 1; }
  cd "$dir" || return 1
  info "开始全流程: $dir"
  build_menu "$dir" || { err "构建失败"; return 1; }
  finaljar=$(find_final_jar "$dir" "$(detect_mod_type "$dir")")
  [[ -z "$finaljar" ]] && { err "找不到 final jar"; return 1; }
  obfuscate_advanced "$dir" "$finaljar" || warn "进阶混淆失败"
  obfjar="${finaljar%.jar}-secure.jar"; [[ ! -f "$obfjar" ]] && obfjar="${finaljar%.jar}-obf.jar"
  if [[ -f "$obfjar" ]]; then publish_release "$dir" "$obfjar"; ensure_zkm && zkm_deobf_single "$obfjar" || warn "ZKM 步骤失败"; deobfpath="$BASE/release/deobf/$(basename "$obfjar" .jar)-deobf.jar"; [[ -f "$deobfpath" ]] && ensure_cfr && cfr_decompile_single "$deobfpath"; fi
  ok "全流程完成: $dir"
}

# -------------------------
# Clear Gradle cache
# -------------------------
clear_gradle_cache(){
  warn "将删除 ~/.gradle/caches（确认）"
  read -p "确认删除 Gradle 缓存？(y/N): " yn; [[ "$yn" =~ ^[Yy]$ ]] || { warn "取消"; return 0; }
  rm -rf "$HOME/.gradle/caches" "$HOME/.gradle/wrapper/dists" 2>/dev/null || true
  gradle --stop 2>/dev/null || true
  ok "Gradle 缓存已清理"
}

# -------------------------
# Main menu
# -------------------------
main_menu(){
  load_config
  check_storage_and_hint
  ensure_basic_tools
  configure_gradle_optimization
  ensure_dir "$TOOLS_DIR" "$BASE/release" "$BASE/release/deobf" "$BASE/decompile"

  while true; do
    echo ""
    echo -e "${CYAN}=== MCDev Ultimate Pipeline (Final) ===${RESET}"
    echo "Project base: $PROJECT_BASE"
    echo "1) 克隆 GitHub 项目 (并进入构建)"
    echo "2) 选择已拉取项目 (构建菜单)"
    echo "3) JDK：自动下载 / 自定义导入"
    echo "4) 安装 / 导入 Gradle (ZIP)"
    echo "5) 安装 Maven"
    echo "6) 下载 Fabric MDK"
    echo "7) 下载 Forge MDK"
    echo "8) 生成 Gradle Wrapper (若缺失)"
    echo "9) 确保 ProGuard (自动下载)"
    echo "10) 确保 ZelixKiller (ZKM) 自动下载"
    echo "11) 构建并混淆单项目"
    echo "12) 批量构建 (projects/*)"
    echo "13) 单项目：全流程 Pipeline (build→obf→zkm→deobf→decompile)"
    echo "14) 批量 ZKM 反混淆 release/*.jar"
    echo "15) CFR 反编译 deobf jar"
    echo "16) 清理 Gradle 缓存"
    echo "17) 显示 / 编辑 PROJECT_BASE"
    echo "0) 退出"
    read -p "选择: " opt
    case "$opt" in
      1) clone_repo ;;
      2) choose_existing_project ;;
      3) auto_install_jdk ;;
      4) install_gradle_from_zip ;;
      5) ensure_maven ;;
      6) download_fabric_mdk ;;
      7) download_forge_mdk ;;
      8) ensure_gradle_wrapper ;;
      9) ensure_proguard ;;
      10) ensure_zkm ;;
      11) choose_existing_project ;;  # enters build_menu
      12) batch_build_all ;;
      13) read -p "项目路径 (留空选择项目): " p; if [[ -z "$p" ]]; then choose_existing_project; else full_pipeline_project "$p"; fi ;;
      14) batch_zkm_deobf ;;
      15) read -p "deobf jar 路径 (回车自动): " j; j=${j:-$(ls "$BASE"/release/deobf/*.jar 2>/dev/null | head -n1)}; [[ -n "$j" ]] && cfr_decompile_single "$j" || warn "未找到 jar" ;;
      16) clear_gradle_cache ;;
      17) echo "当前 PROJECT_BASE=$PROJECT_BASE"; read -p "输入新 PROJECT_BASE (回车保持): " newp; [[ -n "$newp" ]] && { PROJECT_BASE="$newp"; save_config; } ;;
      0) info "退出"; exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

# -------------------------
# start
# -------------------------
ensure_dir "$BASE" "$TOOLS_DIR" "$PROJECTS_LOCAL"
load_config
main_menu
