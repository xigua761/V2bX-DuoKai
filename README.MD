# 交互式,会问你实例名称
bash install-v2bx-multi.sh

# 指定名称,国内机器可加 GitHub 加速前缀
bash install-v2bx-multi.sh -n v2bx-relay -m https://ghfast.top/

# 非交互,直接写好节点信息
API_HOST=https://面板域名 API_KEY=通讯密钥 NODE_ID=12 NODE_TYPE=vless CORE_TYPE=xray \
  bash install-v2bx-multi.sh -n v2bx-relay -y

# 升级 / 卸载
v2bx-relay update
v2bx-relay uninstall


补全文件
cp -n /etc/V2bX/sing_origin.json /etc/V2bX/dns.json /etc/v2bx-2/ 2>/dev/null
sed -i 's|/etc/V2bX|/etc/v2bx-2|g' /etc/v2bx-2/*.json
