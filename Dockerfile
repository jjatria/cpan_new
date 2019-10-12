FROM perl:5.30-slim

RUN apt-get update && apt-get install --yes \
    build-essential openssl zlib1g-dev libssl-dev

COPY cpanfile cpanfile.snapshot ./

RUN cpanm -nq --installdeps .

COPY script/cpan_new.pl cpan-new

RUN chmod 755 cpan-new

CMD cpan-new
