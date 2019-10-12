Consider running with Carton:

    cpanm -nq Carton
    carton install
    carton exec script/cpan_new.pl

or with Docker:

    docker build . --tag cpan-new
    docker run                              \
        --rm                                \
        --volume "$PWD/config":/root/config \
        cpan-new                            \
        --restart always                    \
        ./cpan-new config/credentials.ini
