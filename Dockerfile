# This may be useful for running tests in a container
FROM golang:1.24.2-bookworm AS builder

RUN apt update && apt install -y unzip wget git

# May or may not want `gh` in the container
# RUN wget https://github.com/cli/cli/releases/download/v2.69.0/gh_2.69.0_linux_amd64.deb && dpkg -i gh_2.69.0_linux_amd64.deb && rm gh_2.69.0_linux_amd64.deb

WORKDIR /app

COPY go.mod go.sum ./

RUN go mod download

COPY . .

RUN scripts/build-dev.sh
RUN scripts/help-docker.sh

FROM builder AS test-stage

CMD [ "go", "test", "./...", "-cover"]
