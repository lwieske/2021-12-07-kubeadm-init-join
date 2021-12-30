#!/usr/bin/env bash

# Environment Variables 

set +x

if [[ -z "$AWS_ACCESS_KEY_ID" ]]; then
    echo "... please provide AWS_ACCESS_KEY_ID in environment" 1>&2
    exit 1
fi

if [[ -z "$AWS_SECRET_ACCESS_KEY" ]]; then
    echo "... please provide AWS_SECRET_ACCESS_KEY in environment" 1>&2
    exit 1
fi

if [[ -z "$AWS_DEFAULT_REGION" ]]; then
    echo "... please provide AWS_DEFAULT_REGION in environment" 1>&2
    exit 1
fi

rm -f *.pem

set -x

#######################################################################
### constant / settings
#######################################################################

export PREFIX=AWS_FLATCAR_KUBERNETES

export KEY_NAME=${PREFIX}_KEY
export SECURITY_GROUP_NAME=${PREFIX}_SECURITY_GROUP

export VIP_CIDR_BLOCK=10.0.0.0/16
export PUBLIC_CIDR_BLOCK=10.0.1.0/24

#######################################################################
### create key pair for ssh login
#######################################################################

aws ec2 create-key-pair \
    --key-name ${KEY_NAME} \
    --query 'KeyMaterial' \
    --output text > ${KEY_NAME}.pem

chmod 400 ./${KEY_NAME}.pem

set +x
echo "################################################################################"
echo "### VPC"
echo "################################################################################"
set -x

VPC_ID=`aws ec2 create-vpc \
    --cidr-block ${VIP_CIDR_BLOCK} \
    --query Vpc.VpcId \
    --output text`

aws ec2 modify-vpc-attribute \
    --enable-dns-hostnames \
    --vpc-id ${VPC_ID} 
aws ec2 modify-vpc-attribute \
    --enable-dns-support \
    --vpc-id ${VPC_ID}

set +x
echo "################################################################################"
echo "### Subnet"
echo "################################################################################"
set -x

PUBLIC_SUBNET_ID=`aws ec2 create-subnet \
    --cidr-block 10.0.1.0/24 \
    --vpc-id ${VPC_ID} \
    --query "Subnet.SubnetId" \
    --output text`

set +x
echo "################################################################################"
echo "### Enabling Internet Access (I)"
echo "################################################################################"
set -x

IGW_ID=`aws ec2 create-internet-gateway \
    --query InternetGateway.InternetGatewayId \
    --output text`

aws ec2 attach-internet-gateway \
    --vpc-id ${VPC_ID} \
    --internet-gateway-id ${IGW_ID}

set +x
echo "################################################################################"
echo "### Enabling Internet Access (II)"
echo "################################################################################"
set -x

RTB_ID=`aws ec2 create-route-table \
    --vpc-id ${VPC_ID} \
    --query RouteTable.RouteTableId \
    --output text`

aws ec2 create-route \
    --route-table-id ${RTB_ID} \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id ${IGW_ID}

aws ec2 associate-route-table \
    --subnet-id ${PUBLIC_SUBNET_ID} \
    --route-table-id ${RTB_ID}

set +x
echo "################################################################################"
echo "### Enabling Internet Access (III)"
echo "################################################################################"
set -x

aws ec2 modify-subnet-attribute \
    --subnet-id ${PUBLIC_SUBNET_ID} \
    --map-public-ip-on-launch

set +x
echo "################################################################################"
echo "### Enabling Internet Access (IV)"
echo "################################################################################"
set -x

SECURITY_GROUP_ID=`aws ec2 create-security-group \
    --description "SSH for EXTERNAL_IP_TO_AUTHORIZE" \
    --group-name ${SECURITY_GROUP_NAME} \
    --vpc-id ${VPC_ID} \
    --query 'GroupId' \
    --output text`

aws ec2 wait security-group-exists \
    --group-ids ${SECURITY_GROUP_ID}

EXTERNAL_IP_TO_AUTHORIZE=`curl -s https://checkip.amazonaws.com`

aws ec2 authorize-security-group-ingress \
    --group-id ${SECURITY_GROUP_ID} \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0

set +x
echo "################################################################################"
echo "### Launching"
echo "################################################################################"
set -x

AMI_ID=`aws ec2 describe-images \
    --region eu-central-1 \
    --owners 075585003325 \
    --filters \
                'Name=name,Values=*flatcar-stable*' \
                'Name=architecture,Values=x86_64' \
                'Name=virtualization-type,Values=hvm' \
                'Name=root-device-type,Values=ebs' \
                'Name=image-type,Values=machine' \
    --query 'sort_by(Images, &CreationDate)[-1].[ImageId]' \
    --output text`

INSTANCE_ID=`aws ec2 run-instances \
    --image-id ${AMI_ID} \
    --count 1 \
    --instance-type t2.medium \
    --key-name ${KEY_NAME} \
    --security-group-ids ${SECURITY_GROUP_ID} \
    --subnet-id ${PUBLIC_SUBNET_ID} \
    --query 'Instances[0].InstanceId' \
    --output text`

aws ec2 wait instance-running \
    --instance-ids ${INSTANCE_ID}

INSTANCE_PUBLIC_IP=`aws ec2 describe-instances \
    --instance-ids ${INSTANCE_ID} \
    --query 'Reservations[*].Instances[*].PublicIpAddress' \
    --output text`

set +x
SSH_READY=''
while [ ! $SSH_READY ]; do
    echo "### Waiting 10 seconds for SSH"
    sleep 10
    set +e
    OUT=$(ssh -o ConnectTimeout=1 -o StrictHostKeyChecking=no -o BatchMode=yes ec2-user@${INSTANCE_PUBLIC_IP} 2>&1 | grep 'Permission denied' )
    [[ $? = 0 ]] && SSH_READY='ready'
    set -e
done
set -x

ssh -o StrictHostKeyChecking=no -i ${KEY_NAME}.pem core@${INSTANCE_PUBLIC_IP} -tt <<EOF
    set -x
    sudo kubeadm init \
        --upload-certs
    sleep 20
    sudo kubectl \
        --kubeconfig /etc/kubernetes/admin.conf \
        get nodes
    sudo kubectl \
        --kubeconfig /etc/kubernetes/admin.conf \
        apply -f https://github.com/coreos/flannel/raw/master/Documentation/kube-flannel.yml
    sudo kubectl \
        --kubeconfig /etc/kubernetes/admin.conf \
        get nodes
    sudo kubectl \
        --kubeconfig /etc/kubernetes/admin.conf \
        get pods \
        --all-namespaces
    sleep 20
    exit
EOF

set +x
echo "################################################################################"
echo "### Clean Up"
echo "################################################################################"
set -x

aws ec2 terminate-instances      --instance-ids           ${INSTANCE_ID}
aws ec2 delete-key-pair          --key-name               ${KEY_NAME}
aws ec2 wait instance-terminated --instance-ids           ${INSTANCE_ID}
aws ec2 delete-security-group    --group-id               ${SECURITY_GROUP_ID}
aws ec2 delete-route             --destination-cidr-block 0.0.0.0/0            --route-table-id ${RTB_ID}
aws ec2 detach-internet-gateway  --internet-gateway-id    ${IGW_ID}            --vpc-id ${VPC_ID}
aws ec2 delete-internet-gateway  --internet-gateway-id    ${IGW_ID}
aws ec2 delete-subnet            --subnet-id              ${PUBLIC_SUBNET_ID}
aws ec2 delete-route-table       --route-table-id         ${RTB_ID}
aws ec2 delete-vpc               --vpc-id                 ${VPC_ID}

sleep 20
