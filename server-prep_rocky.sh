#!/bin/bash

# Enable debugging
set -x

# Configuration variables
ANSIBLE_USER="ansible"
SUDO_GROUP="wheel"
SSH_DIR="/home/$ANSIBLE_USER/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
KEY_TYPE="ed25519"
PYTHON_VERSION="3.9"  # Default Python in Rocky Linux 9.3

# Function to display error messages and exit
function error_exit {
    echo "[ERROR] $1" >&2
    exit 1
}

# Function to check if command executed successfully
function check_success {
    if [ $? -ne 0 ]; then
        error_exit "$1"
    fi
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    error_exit "This script must be run as root"
fi

# Update package lists and install EPEL
echo "Configuring repositories and updating packages..."
dnf install -y epel-release
check_success "Failed to install EPEL repository"
dnf update -y
check_success "Failed to update packages"

# Install prerequisite packages
echo "Installing prerequisite packages..."
dnf install -y \
    python3 \
    python3-pip \
    python3-devel \
    git \
    openssh-server \
    openssh-clients \
    sudo \
    libselinux-python3 \
    sshpass \
    gcc \
    make
check_success "Failed to install prerequisite packages"

# Create Ansible user
echo "Creating $ANSIBLE_USER user..."
if id "$ANSIBLE_USER" &>/dev/null; then
    echo "User $ANSIBLE_USER already exists"
else
    useradd -m -s /bin/bash "$ANSIBLE_USER"
    check_success "Failed to create $ANSIBLE_USER user"
fi

# Add user to wheel group (sudo group in RHEL-based systems)
echo "Adding $ANSIBLE_USER to $SUDO_GROUP group..."
usermod -aG "$SUDO_GROUP" "$ANSIBLE_USER"
check_success "Failed to add $ANSIBLE_USER to $SUDO_GROUP group"

# Configure passwordless sudo for Ansible user
echo "Configuring passwordless sudo for $ANSIBLE_USER..."
echo "$ANSIBLE_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ansible
chmod 440 /etc/sudoers.d/ansible
check_success "Failed to configure passwordless sudo"

# Set up SSH directory
echo "Setting up SSH directory for $ANSIBLE_USER..."
mkdir -p "$SSH_DIR"
chown "$ANSIBLE_USER:$ANSIBLE_USER" "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Generate SSH key if it doesn't exist
echo "Generating SSH key for $ANSIBLE_USER..."
if [ ! -f "$SSH_DIR/id_$KEY_TYPE" ]; then
    sudo -u "$ANSIBLE_USER" ssh-keygen -t "$KEY_TYPE" -f "$SSH_DIR/id_$KEY_TYPE" -N ""
    check_success "Failed to generate SSH key"
fi

# Create authorized_keys file
echo "Setting up authorized_keys..."
if [ ! -f "$AUTH_KEYS" ]; then
    sudo -u "$ANSIBLE_USER" cp "$SSH_DIR/id_$KEY_TYPE.pub" "$AUTH_KEYS"
    chown "$ANSIBLE_USER:$ANSIBLE_USER" "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
fi

# Ensure proper permissions for SSH files
echo "Setting correct permissions..."
chown -R "$ANSIBLE_USER:$ANSIBLE_USER" "$SSH_DIR"

# Configure SELinux for SSH key access
echo "Configuring SELinux for SSH..."
restorecon -Rv "$SSH_DIR"
check_success "Failed to configure SELinux for SSH"

# Ensure pip is up to date
echo "Upgrading pip..."
sudo -u "$ANSIBLE_USER" python3 -m pip install --upgrade pip --user
check_success "Failed to upgrade pip"

# Create a virtual environment for Ansible
echo "Creating Python virtual environment for Ansible..."
sudo -u "$ANSIBLE_USER" python3 -m venv "/home/$ANSIBLE_USER/ansible-venv"
check_success "Failed to create virtual environment"

# Install Ansible in the virtual environment
echo "Installing Ansible..."
sudo -u "$ANSIBLE_USER" bash -c "source /home/$ANSIBLE_USER/ansible-venv/bin/activate && pip install ansible && deactivate"
check_success "Failed to install Ansible"

# Create symlink for easy access
echo "Creating symlink for Ansible..."
ln -s "/home/$ANSIBLE_USER/ansible-venv/bin/ansible" "/usr/local/bin/ansible" || echo "Symlink already exists or failed"

# Verify Ansible installation
echo "Verifying Ansible installation..."
sudo -u "$ANSIBLE_USER" /home/$ANSIBLE_USER/ansible-venv/bin/ansible --version
check_success "Ansible installation verification failed"

# Configure SSH service
echo "Configuring SSH service..."
systemctl enable sshd
systemctl restart sshd
check_success "Failed to configure SSH service"

# Configure firewall for SSH
echo "Configuring firewall..."
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --reload
    echo "Firewall configured for SSH"
else
    echo "Firewalld not active, skipping firewall configuration"
fi

# Display completion message
echo -e "\nRocky Linux 9.3 preparation completed successfully!"
echo "Ansible user: $ANSIBLE_USER"
echo "SSH key pair generated at:"
echo "  Private: $SSH_DIR/id_$KEY_TYPE"
echo "  Public:  $SSH_DIR/id_$KEY_TYPE.pub"
echo "Ansible is installed in the virtual environment at: /home/$ANSIBLE_USER/ansible-venv"
echo -e "\nTo use this Ansible control node:"
echo "1. SSH as the Ansible user: ssh -i /path/to/private_key $ANSIBLE_USER@$(hostname -I | awk '{print $1}')"
echo "2. Switch to the Ansible user: sudo su - $ANSIBLE_USER"
echo "3. Activate the virtual environment: source ~/ansible-venv/bin/activate"

# Disable debugging
set +x
