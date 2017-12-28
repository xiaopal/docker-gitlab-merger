FROM alpine:3.7

#ARG ALPINE_MIRROR=http://mirrors.aliyun.com/alpine
ARG NPC_DL_MIRROR=http://npc.nos-eastchina1.126.net/dl

#RUN echo -e "$ALPINE_MIRROR/v3.7/main\n$ALPINE_MIRROR/v3.7/community" >/etc/apk/repositories 
RUN apk add --no-cache bash curl openssh-client openssl nginx findutils \
	&& curl "$NPC_DL_MIRROR/dumb-init_1.2.0_amd64.tar.gz" | tar -zx -C /usr/bin \
	&& curl "$NPC_DL_MIRROR/jq_1.5_linux_amd64.tar.gz" | tar -zx -C /usr/bin
ADD webhook.conf /
ADD run.sh /
RUN chmod a+x /run.sh

EXPOSE 80
ENTRYPOINT [ "/run.sh" ]
CMD ["server"]
