data "template_file" "cloud-config-gpu" {

template = <<EOF

#cloud-config


runcmd:
  - sudo mkdir -p /etc/systemd/system/flanneld.service.d
  - sudo mkdir -p /etc/systemd/system/docker.service.d
  - sudo mkdir -p /run/flannel

write_files:

  - path: /etc/systemd/system/format-ephemeral.service
    content: |
      [Unit]
      Description=Formats the ephemeral drive
      After=dev-xvdf.device
      Requires=dev-xvdf.device
      [Service]
      ExecStart=/sbin/wipefs -f /dev/xvdf
      ExecStart=/sbin/mkfs.ext4 -F /dev/xvdf
      RemainAfterExit=yes
      Type=oneshot


  - path: /etc/systemd/system/var-lib-docker.mount
    content: |
      [Unit]
      Description=Mount ephemeral to /var/lib/docker
      Requires=format-ephemeral.service
      After=format-ephemeral.service
      Before=docker.service
      [Mount]
      What=/dev/xvdf
      Where=/var/lib/docker
      Type=ext4

  - path: /etc/systemd/system/etcd2.service.d/50-etcd-network.conf
    content: |
      [Service]
      Environment="ETCD_DISCOVERY_SRV=${ internal-tld }"
      Environment="ETCD_PEER_TRUSTED_CA_FILE=/etc/kubernetes/ssl/ca.pem"
      Environment="ETCD_PEER_CLIENT_CERT_AUTH=true"
      Environment="ETCD_PEER_CERT_FILE=/etc/kubernetes/ssl/k8s-worker.pem"
      Environment="ETCD_PEER_KEY_FILE=/etc/kubernetes/ssl/k8s-worker-key.pem"
      Environment="ETCD_PROXY=on"


  - path: /etc/systemd/system/flanneld.service
    content: |
      [Unit]
      Description=Network fabric for containers
      Documentation=https://github.com/coreos/flannel
      After=etcd.service etcd2.service
      Before=docker.service

      [Service]
      Type=notify
      Restart=always
      RestartSec=5
      Environment="TMPDIR=/var/tmp/"
      Environment="FLANNEL_VER=v0.6.2"
      Environment="FLANNEL_IMG=quay.io/coreos/flannel"
      Environment="ETCD_SSL_DIR=/etc/ssl/etcd"
      EnvironmentFile=-/run/flannel/options.env
      LimitNOFILE=40000
      LimitNPROC=1048576
      ExecStartPre=/sbin/modprobe ip_tables
      ExecStartPre=/bin/mkdir -p /run/flannel
      ExecStartPre=/bin/mkdir -p /etc/ssl/etcd

      ExecStart=/usr/bin/rkt run --net=host \
      --stage1-path=/usr/lib/rkt/stage1-images/stage1-fly.aci \
      --insecure-options=image \
      --set-env=NOTIFY_SOCKET=/run/systemd/notify \
      --inherit-env=true \
      --volume runsystemd,kind=host,source=/run/systemd,readOnly=false \
      --volume runflannel,kind=host,source=/run/flannel,readOnly=false \
      --volume ssl,kind=host,source=/etc/ssl/etcd,readOnly=true \
      --volume certs,kind=host,source=/usr/share/ca-certificates,readOnly=true \
      --volume resolv,kind=host,source=/etc/resolv.conf,readOnly=true \
      --volume hosts,kind=host,source=/etc/hosts,readOnly=true \
      --mount volume=runsystemd,target=/run/systemd \
      --mount volume=runflannel,target=/run/flannel \
      --mount volume=ssl,target=/etc/ssl/etcd \
      --mount volume=certs,target=/etc/ssl/certs \
      --mount volume=resolv,target=/etc/resolv.conf \
      --mount volume=hosts,target=/etc/hosts \
      $${FLANNEL_IMG}:$${FLANNEL_VER} \
      --exec /opt/bin/flanneld \
      -- --ip-masq=true

      # Update docker options
      ExecStartPost=/usr/bin/rkt run --net=host \
      --stage1-path=/usr/lib/rkt/stage1-images/stage1-fly.aci \
      --insecure-options=image \
      --volume runvol,kind=host,source=/run,readOnly=false \
      --mount volume=runvol,target=/run \
      $${FLANNEL_IMG}:$${FLANNEL_VER} \
      --exec /opt/bin/mk-docker-opts.sh -- -d /run/flannel_docker_opts.env -i

      ExecStopPost=/usr/bin/rkt gc --mark-only

      [Install]
      WantedBy=multi-user.target

  - path: /etc/systemd/system/flanneld.service.d/50-network-config.conf
    content: |
      [Service]
      Restart=always
      RestartSec=10

  - path: /etc/systemd/system/docker.service.d/40-flannel.conf
    content: |
      [Unit]
      After=flanneld.service
      Requires=flanneld.service
      [Service]
      Restart=always
      RestartSec=10

  - path: /etc/systemd/system/s3-get-presigned-url.service
    content: |
      [Unit]
      After=network-online.target
      Description=Install s3-get-presigned-url
      Requires=network-online.target
      [Service]
      ExecStartPre=-/bin/mkdir -p /opt/bin
      ExecStart=/usr/bin/curl -L -o /opt/bin/s3-get-presigned-url \
      https://github.com/kz8s/s3-get-presigned-url/releases/download/v0.1/s3-get-presigned-url_linux_amd64
      ExecStart=/bin/chmod +x /opt/bin/s3-get-presigned-url
      RemainAfterExit=yes
      Type=oneshot

  - path: /etc/systemd/system/get-ssl.service
    content: |
      [Unit]
      After=s3-get-presigned-url.service
      Description=Get ssl artifacts from s3 bucket using IAM role
      Requires=s3-get-presigned-url.service
      [Service]
      ExecStartPre=-/bin/mkdir -p /etc/kubernetes/ssl
      ExecStart=/bin/sh -c "/usr/bin/curl $(/opt/bin/s3-get-presigned-url \
      ${ region } ${ bucket } ${ ssl-tar }) | tar xv -C /etc/kubernetes/ssl/"
      RemainAfterExit=yes
      Type=oneshot

  - path: /etc/systemd/system/kubelet.service
    content: |
      [Unit]
      ConditionFileIsExecutable=/opt/bin/kubelet-wrapper
      [Service]
      Environment="KUBELET_ACI=${ hyperkube-image }"
      Environment="KUBELET_VERSION=${ hyperkube-tag }"
      Environment="RKT_OPTS=\
        --volume dns,kind=host,source=/etc/resolv.conf \
        --mount volume=dns,target=/etc/resolv.conf \
        --volume rkt,kind=host,source=/opt/bin/host-rkt \
        --mount volume=rkt,target=/usr/bin/rkt \
        --volume var-lib-rkt,kind=host,source=/var/lib/rkt \
        --mount volume=var-lib-rkt,target=/var/lib/rkt \
        --volume stage,kind=host,source=/tmp \
        --mount volume=stage,target=/tmp \
        --volume var-log,kind=host,source=/var/log \
        --mount volume=var-log,target=/var/log"
      ExecStartPre=/bin/mkdir -p /var/log/containers
      ExecStartPre=/bin/mkdir -p /etc/kubernetes/manifests
      ExecStartPre=/bin/mkdir -p /var/lib/kubelet
      ExecStartPre=/bin/mount --bind /var/lib/kubelet /var/lib/kubelet
      ExecStartPre=/bin/mount --make-shared /var/lib/kubelet
      ExecStart=/opt/bin/kubelet-wrapper \
        --allow-privileged=true \
        --api-servers=http://master.${ internal-tld }:8080 \
        --cloud-provider=aws \
        --cluster-dns=${ dns-service-ip } \
        --cluster-domain=${ cluster-domain } \
        --config=/etc/kubernetes/manifests \
        --kubeconfig=/etc/kubernetes/kubeconfig.yml \
        --register-node=true \
        --tls-cert-file=/etc/kubernetes/ssl/k8s-worker.pem \
        --tls-private-key-file=/etc/kubernetes/ssl/k8s-worker-key.pem \
        --experimental-nvidia-gpus=1
      Restart=always
      RestartSec=5
      [Install]
      WantedBy=multi-user.target





  - path: /opt/bin/host-rkt
    permissions: 0755
    owner: root:root
    content: |
      #!/bin/sh
      exec nsenter -m -u -i -n -p -t 1 -- /usr/bin/rkt "$@"

  - path: /etc/kubernetes/kubeconfig.yml
    content: |
      apiVersion: v1
      kind: Config
      clusters:
      - name: local
      cluster:
      certificate-authority: /etc/kubernetes/ssl/ca.pem
      users:
      - name: kubelet
      user:
      client-certificate: /etc/kubernetes/ssl/k8s-worker.pem
      client-key: /etc/kubernetes/ssl/k8s-worker-key.pem
      contexts:
      - context:
      cluster: local
      user: kubelet
      name: kubelet-context
      current-context: kubelet-context

  - path: /etc/kubernetes/manifests/kube-proxy.yml
    content: |
      apiVersion: v1
      kind: Pod
      metadata:
      name: kube-proxy
      namespace: kube-system
      spec:
      hostNetwork: true
      containers:
      - name: kube-proxy
      image: ${ hyperkube-image }:${ hyperkube-tag }
      command:
      - /hyperkube
      - proxy
      - --kubeconfig=/etc/kubernetes/kubeconfig.yml
      - --master=https://master.${ internal-tld }
      - --proxy-mode=iptables
      securityContext:
      privileged: true
      volumeMounts:
      - mountPath: /etc/ssl/certs
      name: "ssl-certs"
      - mountPath: /etc/kubernetes/kubeconfig.yml
      name: "kubeconfig"
      readOnly: true
      - mountPath: /etc/kubernetes/ssl
      name: "etc-kube-ssl"
      readOnly: true
      volumes:
      - name: "ssl-certs"
      hostPath:
      path: "/usr/share/ca-certificates"
      - name: "kubeconfig"
      hostPath:
      path: "/etc/kubernetes/kubeconfig.yml"
      - name: "etc-kube-ssl"
      hostPath:
      path: "/etc/kubernetes/ssl"

runcmd:
  - sudo systemctl daemon-reload
  - sudo systemctl start get-ssl.service
  - sleep 30s
  - sudo systemctl enable get-ssl.service
  - sudo rm -rf /var/lib/etcd/*
  - sudo systemctl stop etcd.service
  - sudo systemctl enable etcd2.service
  - sudo systemctl restart etcd2.service
  - sudo systemctl stop docker.service
  - sudo systemctl enable --now var-lib-docker.mount
  - sudo systemctl start docker.service
  - sudo systemctl enable --now kubelet.service

EOF

  vars {
    bucket = "${ var.bucket-prefix }"
    cluster-domain = "${ var.cluster-domain }"
    hyperkube-image = "${ var.hyperkube-image }"
    hyperkube-tag = "${ var.hyperkube-tag }"
    dns-service-ip = "${ var.dns-service-ip }"
    internal-tld = "${ var.internal-tld }"
    region = "${ var.region }"
    ssl-tar = "/ssl/k8s-worker.tar"
  }
}
