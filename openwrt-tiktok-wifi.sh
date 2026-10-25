#!/bin/sh
# 在 OpenWrt / Kwrt 上创建独立 WiFi，并把该网段的访问控制绑定到一条 VLESS Reality 节点。
# 只接受主机名为 www.<字母>.diandongyun.org 的 vless 链接。

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

fail() {
	printf '%s\n' "$1"
	exit 1
}

urldecode() {
	printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"
}

qget() {
	printf '%s' "$1" | tr '&' '\n' | sed -n "s/^$2=//p" | head -n 1
}

pkg_installed() {
	if command -v apk >/dev/null 2>&1; then
		apk info -e "$1" >/dev/null 2>&1
		return $?
	fi
	command -v opkg >/dev/null 2>&1 || return 1
	opkg list-installed "$1" 2>/dev/null | grep -q "^$1 "
}

OPKG_UPDATED=0
opkg_install() {
	pkg_installed "$1" && return 0
	if command -v apk >/dev/null 2>&1; then
		echo "正在安装 $1 ..."
		apk add "$1" || fail "安装 $1 失败"
		return 0
	fi
	command -v opkg >/dev/null 2>&1 || fail "系统没有 opkg 或 apk，无法安装 $1"
	if [ "$OPKG_UPDATED" = "0" ]; then
		echo "正在更新软件源..."
		opkg update || fail "无法更新软件源，请检查路由器是否能上网"
		OPKG_UPDATED=1
	fi
	echo "正在安装 $1 ..."
	opkg install "$1" || fail "安装 $1 失败"
}

bin_has() {
	if command -v strings >/dev/null 2>&1; then
		strings "$1" 2>/dev/null | grep -q "$2"
		return $?
	fi
	grep -a -q "$2" "$1" 2>/dev/null
}

chinese_bytes() {
	# 「中」的 UTF-8 是 e4 b8 ad。这台系统没有 od，用 hexdump。
	if command -v hexdump >/dev/null 2>&1; then
		printf '中' | hexdump -v -e '1/1 "%02x"'
		return 0
	fi
	if command -v od >/dev/null 2>&1; then
		printf '中' | od -An -tx1 | tr -d ' \n'
		return 0
	fi
	printf '中' | wc -c | tr -d ' \n'
}

ensure_cli_chinese() {
	# 交互发生在当前 shell。LuCI 的 zh-cn 语言包只翻译网页，不改变命令行输出。
	# 这套固件没有可安装的命令行中文 locale，提示语按 UTF-8 字节直接发给终端。
	export LANG=C.UTF-8
	export LC_ALL=C.UTF-8
	echo "检查当前命令行能否输出简体中文..."
	cn_hex=$(chinese_bytes)
	case "$cn_hex" in
		*e4b8ad*|3)
			echo "命令行可以显示简体中文"
			return 0
			;;
	esac
	fail "CLI cannot print UTF-8 Chinese, stop."
}

xray_supports_vless() {
	bin="$1"
	[ -n "$bin" ] && [ -x "$bin" ] || return 1
	bin_has "$bin" 'xtls-rprx-vision' || return 1
	bin_has "$bin" 'vless' || return 1
	bin_has "$bin" 'reality' || return 1
}

ensure_components() {
	echo "检查 PassWall 与 VLESS 所需组件..."
	if [ ! -x /etc/init.d/passwall ]; then
		opkg_install luci-app-passwall
	fi
	[ -x /etc/init.d/passwall ] || fail "未安装 passwall"
	uci -q get passwall.@global[0] >/dev/null 2>&1 || fail "passwall 配置不完整"

	xray_bin=$(uci -q get passwall.@global_app[0].xray_file)
	[ -n "$xray_bin" ] || xray_bin=$(command -v xray)
	if ! xray_supports_vless "$xray_bin"; then
		echo "Xray 缺失或不支持 VLESS Reality，正在安装 xray-core..."
		opkg_install xray-core
		xray_bin=$(command -v xray)
		xray_supports_vless "$xray_bin" || fail "xray-core 已安装，但仍不支持 VLESS Reality"
	fi
	if uci -q get passwall.@global_app[0] >/dev/null 2>&1; then
		cur_xray=$(uci -q get passwall.@global_app[0].xray_file)
		if [ "$cur_xray" != "$xray_bin" ]; then
			uci set passwall.@global_app[0].xray_file="$xray_bin"
			uci commit passwall
		fi
	fi
	echo "PassWall 与 Xray（VLESS Reality）已就绪: $xray_bin"
}

ask_inputs() {
	echo ""
	echo "1. 选择 WiFi 频段"
	echo "   1) 2.4GHz"
	echo "   2) 5GHz"
	printf "请输入数字后回车: "
	read -r BAND_CHOICE
	BAND_CHOICE=$(printf '%s' "$BAND_CHOICE" | tr -d ' \r')
	case "$BAND_CHOICE" in
		1) BAND="2g" ;;
		2) BAND="5g" ;;
		*) fail "无效频段，请输入 1 或 2" ;;
	esac

	echo ""
	printf '2. 请输入 WiFi 名称。请使用英文、数字、空格、点、下划线或短横线。（\033[1;31m禁止使用中文\033[0m）\n'
	printf "WiFi 名称: "
	read -r SSID
	SSID=$(printf '%s' "$SSID" | tr -d '\r')
	printf '%s' "$SSID" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,31}$' || fail "WiFi 名称需要使用英文，且不能包含引号"
	for sec in $(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([A-Za-z0-9_]*\)=wifi-iface$/\1/p"); do
		got=$(uci -q get "wireless.${sec}.ssid")
		if [ "$got" = "$SSID" ]; then
			fail "WiFi 名称 ${SSID} 已存在，已终止，未修改配置"
		fi
	done

	echo ""
	printf '3. 请输入 WiFi 密码，8 到 63 位英文字符，不要包含引号、反斜杠、美元符号或反引号。（\033[1;31m禁止使用中文\033[0m）\n'
	printf "WiFi 密码: "
	read -r WIFI_PASS
	WIFI_PASS=$(printf '%s' "$WIFI_PASS" | tr -d '\r')ok
	pass_len=${#WIFI_PASS}
	[ "$pass_len" -ge 8 ] && [ "$pass_len" -le 63 ] || fail "WiFi 密码需要 8 到 63 位"
	printf '%s' "$WIFI_PASS" | grep -q '[^ -~]' && fail "WiFi 密码请使用英文字符"
	case "$WIFI_PASS" in
		*[\'\"\$\`\\]*) fail "WiFi 密码不要包含引号、反斜杠、美元符号或反引号" ;;
	esac

	echo ""
	echo "4. 请输入要绑定到该 WiFi 的 VLESS 节点链接。"
	printf "节点: "
	read -r NODE_URL
	NODE_URL=$(printf '%s' "$NODE_URL" | tr -d '\r')
}

parse_node() {
	case "$NODE_URL" in
		vless://*) ;;
		*) fail "不兼容" ;;
	esac

	rest=${NODE_URL#vless://}
	case "$rest" in
		*\#*)
			NODE_REMARKS=$(urldecode "${rest#*#}")
			rest=${rest%%\#*}
			;;
		*) NODE_REMARKS="" ;;
	esac
	case "$rest" in
		*\?*)
			userhost=${rest%%\?*}
			query=${rest#*\?}
			;;
		*) fail "不兼容" ;;
	esac

	NODE_UUID=${userhost%%@*}
	hostport=${userhost#*@}
	[ "$hostport" != "$userhost" ] || fail "不兼容"
	NODE_HOST=$(printf '%s' "${hostport%%:*}" | tr 'A-Z' 'a-z')
	NODE_PORT=${hostport##*:}

	printf '%s' "$NODE_HOST" | grep -Eq '^www\.[A-Za-z]+\.diandongyun\.org$' || fail "不兼容"
	printf '%s' "$NODE_PORT" | grep -Eq '^[0-9]+$' || fail "不兼容"
	[ "$NODE_PORT" -ge 1 ] && [ "$NODE_PORT" -le 65535 ] || fail "不兼容"
	printf '%s' "$NODE_UUID" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' || fail "不兼容"

	NODE_TYPE=$(qget "$query" type)
	NODE_SECURITY=$(qget "$query" security)
	NODE_PBK=$(urldecode "$(qget "$query" pbk)")
	NODE_FP=$(qget "$query" fp)
	NODE_SNI=$(qget "$query" sni)
	NODE_SID=$(qget "$query" sid)
	NODE_FLOW=$(qget "$query" flow)
	NODE_ENC=$(qget "$query" encryption)
	[ -n "$NODE_TYPE" ] || NODE_TYPE=tcp
	[ -n "$NODE_FP" ] || NODE_FP=chrome
	[ -n "$NODE_ENC" ] || NODE_ENC=none

	[ "$NODE_TYPE" = "tcp" ] || [ "$NODE_TYPE" = "raw" ] || fail "不兼容"
	[ "$NODE_SECURITY" = "reality" ] || fail "不兼容"
	[ "$NODE_FLOW" = "xtls-rprx-vision" ] || fail "不兼容"
	[ "$NODE_ENC" = "none" ] || fail "不兼容"
	[ -n "$NODE_PBK" ] && [ -n "$NODE_SNI" ] && [ -n "$NODE_SID" ] || fail "不兼容"

	[ -n "$NODE_REMARKS" ] || NODE_REMARKS="$NODE_HOST"
	NODE_REMARKS=$(printf '%s' "$NODE_REMARKS" | tr -d "'\"\\")
}

radio_matches_band() {
	got=$(uci -q get "wireless.$1.band")
	[ -z "$got" ] && got=$(uci -q get "wireless.$1.hwmode")
	case "$got" in
		2g|11g|11ng|11b|11bg) [ "$BAND" = "2g" ] ;;
		5g|11a|11na|11ac|11ax) [ "$BAND" = "5g" ] ;;
		*) return 1 ;;
	esac
}

pick_radio() {
	for radio in radio0 radio1 radio2 radio3; do
		uci -q get "wireless.${radio}" >/dev/null 2>&1 || continue
		if radio_matches_band "$radio"; then
			RADIO=$radio
			return 0
		fi
	done
	fail "没有找到 ${BAND} 无线设备"
}

ht_supported() {
	printf '%s' "$HT_INFO" | grep -Eq "(^|[^A-Za-z0-9])$1([^A-Za-z0-9]|$)"
}

pick_htmode() {
	if [ "$BAND" = "2g" ]; then
		HT_LIST="HE40 HT40 HE20 HT20"
	else
		HT_LIST="EHT320 EHT160 HE160 VHT160 EHT80 HE80 VHT80 HE40 VHT40 HT40 HE20 VHT20 HT20"
	fi
	HT_INFO=$(ubus call iwinfo info "{\"device\":\"${RADIO}\"}" 2>/dev/null)
	[ -n "$HT_INFO" ] || HT_INFO=$(iwinfo "$RADIO" info 2>/dev/null)
	HT_TRY=""
	for mode in $HT_LIST; do
		if [ -z "$HT_INFO" ] || ht_supported "$mode"; then
			HT_TRY="$HT_TRY $mode"
		fi
	done
	[ -n "$HT_TRY" ] || HT_TRY="HT20"
	OLD_HTMODE=$(uci -q get "wireless.${RADIO}.htmode")
	HTMODE=$(printf '%s' "$HT_TRY" | awk '{print $1}')
}

pick_names() {
	IFACE=$(printf '%s' "$SSID" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '_' | sed 's/^_*//; s/_*$//; s/__*/_/g')
	case "$IFACE" in
		[a-z]*) ;;
		*) IFACE="w${IFACE}" ;;
	esac
	# 桥设备名是 br-接口名。Linux 网卡名最长 15，所以接口名最多 12。
	IFACE=$(printf '%s' "$IFACE" | cut -c 1-12)
	[ -n "$IFACE" ] || fail "无法从 WiFi 名称生成接口名"
	base_iface=$IFACE
	n=2
	while uci -q get "network.${IFACE}" >/dev/null 2>&1 || uci -q get "dhcp.${IFACE}" >/dev/null 2>&1 || uci show network 2>/dev/null | grep -Fq "name='br-${IFACE}'"; do
		suf=$n
		keep=$((12 - ${#suf}))
		[ "$keep" -ge 1 ] || fail "无法从 WiFi 名称生成可用接口名"
		IFACE="$(printf '%s' "$base_iface" | cut -c 1-$keep)${suf}"
		n=$((n + 1))
		[ "$n" -le 99 ] || fail "无法从 WiFi 名称生成可用接口名"
	done

	SUBNET=""
	n=21
	while [ "$n" -le 250 ]; do
		[ "$n" -eq 100 ] && n=$((n + 1)) && continue
		if ip -4 addr 2>/dev/null | grep -q "192\.168\.${n}\."; then
			n=$((n + 1))
			continue
		fi
		if uci show network 2>/dev/null | grep -q "192\.168\.${n}\."; then
			n=$((n + 1))
			continue
		fi
		SUBNET=$n
		break
	done
	[ -n "$SUBNET" ] || fail "没有可用的 192.168 网段"
	GW="192.168.${SUBNET}.1"
}

repair_invalid_network() {
	i=0
	while uci -q get "network.@route[${i}]" >/dev/null 2>&1; do
		iface=$(uci -q get "network.@route[${i}].interface")
		if [ -z "$iface" ] || [ "$iface" = '${INTERFACE_NAME}' ] || ! uci -q get "network.${iface}" >/dev/null 2>&1; then
			uci -q delete "network.@route[${i}]"
		else
			i=$((i + 1))
		fi
	done

	i=0
	while uci -q get "network.@device[${i}]" >/dev/null 2>&1; do
		name=$(uci -q get "network.@device[${i}].name")
		ports=$(uci -q get "network.@device[${i}].ports")
		if [ -n "$name" ] && [ "$ports" = "$name" ]; then
			uci -q delete "network.@device[${i}].ports"
			echo "已去掉桥 ${name} 指向自己的端口"
		fi
		i=$((i + 1))
	done
}

import_node() {
	NODE_ID=""
	for sec in $(uci show passwall 2>/dev/null | sed -n "s/^passwall\.\([A-Za-z0-9_]*\)=nodes$/\1/p"); do
		[ "$(uci -q get "passwall.${sec}.protocol")" = "vless" ] || continue
		[ "$(uci -q get "passwall.${sec}.address")" = "$NODE_HOST" ] || continue
		[ "$(uci -q get "passwall.${sec}.port")" = "$NODE_PORT" ] || continue
		[ "$(uci -q get "passwall.${sec}.uuid")" = "$NODE_UUID" ] || continue
		NODE_ID=$sec
		break
	done

	if [ -z "$NODE_ID" ]; then
		NODE_ID="n$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 7)"
		uci set "passwall.${NODE_ID}=nodes"
	fi

	uci set "passwall.${NODE_ID}.protocol=vless"
	uci set "passwall.${NODE_ID}.type=Xray"
	uci set "passwall.${NODE_ID}.address=${NODE_HOST}"
	uci set "passwall.${NODE_ID}.port=${NODE_PORT}"
	uci set "passwall.${NODE_ID}.uuid=${NODE_UUID}"
	uci set "passwall.${NODE_ID}.encryption=none"
	uci set "passwall.${NODE_ID}.flow=xtls-rprx-vision"
	uci set "passwall.${NODE_ID}.transport=raw"
	uci set "passwall.${NODE_ID}.tcp_guise=none"
	uci set "passwall.${NODE_ID}.tls=1"
	uci set "passwall.${NODE_ID}.tls_allowInsecure=0"
	uci set "passwall.${NODE_ID}.reality=1"
	uci set "passwall.${NODE_ID}.utls=1"
	uci set "passwall.${NODE_ID}.fingerprint=${NODE_FP}"
	uci set "passwall.${NODE_ID}.tls_serverName=${NODE_SNI}"
	uci set "passwall.${NODE_ID}.reality_publicKey=${NODE_PBK}"
	uci set "passwall.${NODE_ID}.reality_shortId=${NODE_SID}"
	uci set "passwall.${NODE_ID}.remarks=${NODE_REMARKS}"
	uci set "passwall.${NODE_ID}.timeout=60"
	uci set "passwall.${NODE_ID}.add_mode=1"
	uci set "passwall.${NODE_ID}.add_from=脚本导入"
}

configure_wifi() {
	if uci show network 2>/dev/null | grep -q '=device$' || [ -x /sbin/fw4 ]; then
		uci add network device >/dev/null
		uci set network.@device[-1].name="br-${IFACE}"
		uci set network.@device[-1].type='bridge'
		uci set network.@device[-1].bridge_empty='1'
		uci set "network.${IFACE}=interface"
		uci set "network.${IFACE}.device=br-${IFACE}"
	else
		uci set "network.${IFACE}=interface"
		uci set "network.${IFACE}.type=bridge"
	fi
	uci set "network.${IFACE}.proto=static"
	uci set "network.${IFACE}.ipaddr=${GW}"
	uci set "network.${IFACE}.netmask=255.255.255.0"
	uci set "network.${IFACE}.delegate=0"
	uci set "network.${IFACE}.defaultroute=0"
	uci set "network.${IFACE}.ipv6=0"

	uci set "dhcp.${IFACE}=dhcp"
	uci set "dhcp.${IFACE}.interface=${IFACE}"
	uci set "dhcp.${IFACE}.start=100"
	uci set "dhcp.${IFACE}.limit=100"
	uci set "dhcp.${IFACE}.leasetime=12h"
	uci set "dhcp.${IFACE}.dhcpv4=server"
	uci set "dhcp.${IFACE}.dhcpv6=disabled"
	uci set "dhcp.${IFACE}.ra=disabled"
	uci add_list "dhcp.${IFACE}.dhcp_option=6,${GW}"

	uci add firewall zone >/dev/null
	uci set firewall.@zone[-1].name="${IFACE}"
	uci set firewall.@zone[-1].input='ACCEPT'
	uci set firewall.@zone[-1].output='ACCEPT'
	uci set firewall.@zone[-1].forward='REJECT'
	uci add_list firewall.@zone[-1].network="${IFACE}"
	uci set firewall.@zone[-1].masq='1'
	uci set firewall.@zone[-1].mtu_fix='1'
	uci set firewall.@zone[-1].masq6='0'

	uci add firewall rule >/dev/null
	uci set firewall.@rule[-1].name="allow_${IFACE}_dhcp_dns"
	uci set firewall.@rule[-1].src="${IFACE}"
	uci set firewall.@rule[-1].dest_port='53 67 68'
	uci set firewall.@rule[-1].proto='udp'
	uci set firewall.@rule[-1].target='ACCEPT'

	uci add firewall rule >/dev/null
	uci set firewall.@rule[-1].name="allow_${IFACE}_dns_tcp"
	uci set firewall.@rule[-1].src="${IFACE}"
	uci set firewall.@rule[-1].dest_port='53'
	uci set firewall.@rule[-1].proto='tcp'
	uci set firewall.@rule[-1].target='ACCEPT'

	uci add firewall rule >/dev/null
	uci set firewall.@rule[-1].name="block_${IFACE}_admin"
	uci set firewall.@rule[-1].src="${IFACE}"
	uci set firewall.@rule[-1].dest_port='22 80 443 7681'
	uci set firewall.@rule[-1].proto='tcp'
	uci set firewall.@rule[-1].target='REJECT'

	n=0
	while uci -q get "wireless.wifinet${n}" >/dev/null 2>&1; do
		n=$((n + 1))
	done
	WIFINET="wifinet${n}"

	uci set "wireless.${RADIO}.disabled=0"
	uci set "wireless.${WIFINET}=wifi-iface"
	uci set "wireless.${WIFINET}.device=${RADIO}"
	uci set "wireless.${WIFINET}.network=${IFACE}"
	uci set "wireless.${WIFINET}.mode=ap"
	uci set "wireless.${WIFINET}.ssid=${SSID}"
	uci set "wireless.${WIFINET}.encryption=psk2"
	uci set "wireless.${WIFINET}.key=${WIFI_PASS}"
	uci set "wireless.${WIFINET}.isolate=1"
	uci set "wireless.${WIFINET}.wmm=1"
	uci set "wireless.${WIFINET}.disabled=0"
}

configure_acl() {
	uci set passwall.@global[0].acl_enable='1'

	uci add passwall acl_rule >/dev/null
	uci set passwall.@acl_rule[-1].enabled='1'
	uci set passwall.@acl_rule[-1].remarks="${SSID}"
	uci set "passwall.@acl_rule[-1].interface=${IFACE}"
	uci set "passwall.@acl_rule[-1].sources=192.168.${SUBNET}.0/24"
	uci set passwall.@acl_rule[-1].use_global_config='0'
	uci set "passwall.@acl_rule[-1].tcp_node=${NODE_ID}"
	uci set "passwall.@acl_rule[-1].udp_node=${NODE_ID}"
	uci set passwall.@acl_rule[-1].tcp_proxy_mode='proxy'
	uci set passwall.@acl_rule[-1].udp_proxy_mode='proxy'
	uci set passwall.@acl_rule[-1].tcp_no_redir_ports='disable'
	uci set passwall.@acl_rule[-1].udp_no_redir_ports='disable'
	uci set passwall.@acl_rule[-1].tcp_proxy_drop_ports='disable'
	uci set passwall.@acl_rule[-1].udp_proxy_drop_ports='disable'
	uci set passwall.@acl_rule[-1].tcp_redir_ports='1:65535'
	uci set passwall.@acl_rule[-1].udp_redir_ports='1:65535'
	uci set passwall.@acl_rule[-1].use_direct_list='0'
	uci set passwall.@acl_rule[-1].use_proxy_list='0'
	uci set passwall.@acl_rule[-1].use_block_list='0'
	uci set passwall.@acl_rule[-1].use_gfw_list='0'
	uci set passwall.@acl_rule[-1].chn_list='0'
	uci set passwall.@acl_rule[-1].dns_shunt='dnsmasq'
	uci set passwall.@acl_rule[-1].dns_mode='xray'
	uci set passwall.@acl_rule[-1].v2ray_dns_mode='tcp'
	uci set passwall.@acl_rule[-1].remote_dns='1.1.1.1'
	uci set passwall.@acl_rule[-1].filter_proxy_ipv6='1'
	uci set passwall.@acl_rule[-1].use_default_dns='remote'
}

bridge_up() {
	ip -4 addr show "br-${IFACE}" 2>/dev/null | grep -q "${GW}/"
}

ssid_up() {
	wifi status 2>/dev/null | grep -F "\"ssid\": \"${SSID}\"" >/dev/null 2>&1
}

wait_ssid() {
	n=0
	while [ "$n" -lt 12 ]; do
		ssid_up && return 0
		n=$((n + 1))
		sleep 1
	done
	return 1
}

set_width() {
	uci set "wireless.${RADIO}.htmode=$1"
	if [ "$BAND" = "2g" ]; then
		case "$1" in
			*40*) uci set "wireless.${RADIO}.noscan=1" ;;
			*) uci -q delete "wireless.${RADIO}.noscan" ;;
		esac
	else
		case "$1" in
			*160*|*320*) uci set "wireless.${RADIO}.channel=36" ;;
			*) [ -n "$OLD_CHANNEL" ] && uci set "wireless.${RADIO}.channel=${OLD_CHANNEL}" ;;
		esac
	fi
	uci commit wireless
	wifi reload
}

apply_htmode() {
	OLD_CHANNEL=$(uci -q get "wireless.${RADIO}.channel")
	cur=$(uci -q get "wireless.${RADIO}.htmode")
	if ssid_up; then
		for mode in $HT_TRY; do
			if [ "$mode" = "$cur" ]; then
				HTMODE=$cur
				return 0
			fi
			echo "尝试把信道宽度从 ${cur} 提高到 ${mode}"
			set_width "$mode"
			if wait_ssid; then
				HTMODE=$mode
				return 0
			fi
			echo "信道宽度 ${mode} 未能启动，保持 ${cur}"
			set_width "$cur"
			wait_ssid || true
			HTMODE=$cur
			return 0
		done
	fi
	for mode in $HT_TRY; do
		echo "尝试信道宽度 ${mode}"
		set_width "$mode"
		if wait_ssid; then
			HTMODE=$mode
			return 0
		fi
		echo "信道宽度 ${mode} 未能启动，尝试更低的宽度"
	done
	[ -n "$OLD_HTMODE" ] && uci set "wireless.${RADIO}.htmode=${OLD_HTMODE}"
	[ -n "$OLD_CHANNEL" ] && uci set "wireless.${RADIO}.channel=${OLD_CHANNEL}"
	uci commit wireless
	wifi reload
	return 1
}

apply_and_refresh() {
	echo "正在保存并刷新接口、无线、防火墙和 PassWall..."
	uci commit network
	uci commit wireless
	uci commit dhcp
	uci commit firewall
	uci commit passwall

	/etc/init.d/network reload
	ifup "$IFACE"
	/etc/init.d/firewall reload
	/etc/init.d/dnsmasq restart
	n=0
	while [ "$n" -lt 8 ]; do
		bridge_up && break
		n=$((n + 1))
		sleep 1
	done
	bridge_up || fail "接口 br-${IFACE} 没有起来。网卡名最长 15 个字符，请查看 logread"
	apply_htmode || fail "配置已写入，但 ${SSID} 没有起来。请查看 logread"
	/etc/init.d/passwall restart
	/sbin/reload_config
	rm -f /tmp/luci-indexcache
	rm -rf /tmp/luci-modulecache
	bridge_up && ssid_up || fail "配置已写入，但 ${SSID} 或 br-${IFACE} 没有起来。请查看 logread 与 /tmp/log/passwall.log"
}

print_summary() {
	echo ""
	echo "======================================"
	echo "配置已保存并刷新。"
	echo "WiFi 名称: ${SSID}"
	echo "WiFi 密码: ${WIFI_PASS}"
	echo "频段: ${BAND}"
	echo "网关: ${GW}"
	echo "节点: ${NODE_REMARKS}"
	echo ""
	echo "1. 为 ${SSID} 单独建立接口 ${IFACE}、网段 192.168.${SUBNET}.0/24 和防火墙区域，不进入家庭局域网，也不作为路由器的默认出口，避免终端扫到家庭设备。"
	echo "2. 访问控制只处理源接口 ${IFACE}，TCP/UDP 都使用 ${NODE_REMARKS}，避免源接口为空时匹配所有接口，没被匹配到的流量从家庭宽带直接出去。"
	echo "3. 未进入节点的流量不允许转发到 WAN，避免家庭宽带地址泄露，防止节点中断时该 WiFi 自动换成家庭宽带，造成连接暴露。"
	echo "4. TCP、UDP 和 DNS 全部从 ${NODE_REMARKS} 出去，网页、视频、DNS 和 WebRTC/STUN 使用同一出口，避免国内 DNS 或随机 UDP 绕过代理后读到家庭宽带地址杜绝DNS泄露。"
	echo "5. 直连列表、代理列表、屏蔽列表、GFW 列表、中国列表都关闭，并且不继承 PassWall 全局配置，避免全局规则或国内分流把一部分网站留在家庭网络。"
	echo "6. 关闭该接口的 IPv6，并丢弃代理返回的 IPv6，避免 IPv6 绕过 IPv4 代理，暴露家庭网络的 IPv6 地址。"
	echo "7. 拒绝该 WiFi 访问路由器的 22、80、443、7681 端口，连上 ${SSID} 的设备打不开后台，避免探测或误入管理页面。"
	echo "8. 信道宽度使用当前能够启动的最高档 ${HTMODE}，提高多台设备同时使用时的速率。"
	echo "======================================"
	echo ""
	printf '\033#6\033[1m可以再次执行此命令创建更多配置\033[0m\n'
}

echo "======================================"
echo "WiFi 与 VLESS 节点配置"
echo "======================================"

ensure_cli_chinese
ensure_components
ask_inputs
parse_node
pick_radio
pick_htmode
pick_names

echo ""
echo "将创建:"
echo "  频段: ${BAND} (${RADIO})"
echo "  优先信道宽度: ${HTMODE}"
echo "  名称: ${SSID}"
echo "  接口: ${IFACE}"
echo "  网段: 192.168.${SUBNET}.0/24"
echo "  节点: ${NODE_REMARKS} (${NODE_HOST}:${NODE_PORT})"

repair_invalid_network
import_node
configure_wifi
configure_acl
apply_and_refresh
print_summary
