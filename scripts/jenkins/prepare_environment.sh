wget https://raw.githubusercontent.com/esbmc/esbmc/master/scripts/competitions/svcomp/esbmc-wrapper.py ; chmod +x esbmc-wrapper.py ; unzip esbmc.zip ; mv ./build/ESBMC-Linux.sh . ; chmod +x ESBMC-Linux.sh ; ./ESBMC-Linux.sh --skip-license ; mv bin/esbmc . ; chmod +x esbmc