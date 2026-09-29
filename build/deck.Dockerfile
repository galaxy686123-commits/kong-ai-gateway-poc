# decK + 선언형 설정 파일. 설정을 이미지에 담아 전달한다.
ARG DECK_IMAGE=kong/deck:v1.65.1
FROM ${DECK_IMAGE}
COPY conf/ /conf/
