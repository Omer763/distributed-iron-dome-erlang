FROM erlang:27-slim

# Install SSH server and sudo
RUN apt-get update && apt-get install -y openssh-server sudo && \
    mkdir /var/run/sshd

# Create user 'tal' with password '1234'
RUN useradd -m -s /bin/bash tal && \
    echo "tal:1234" | chpasswd && \
    usermod -aG sudo tal

# Enable password authentication
RUN sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

EXPOSE 22 9100 4369

# Start SSH daemon in the foreground (no automatic Erlang execution)
CMD ["/usr/sbin/sshd", "-D"]