# Contexto de negócio

Uma companhia monitoramento de saúde de máquina industriais possui um sensor de vibração com as seguinte configurações de amostragem, conforme a tabela 1.

    Tabela 1. Configuração de Amostras                              
    +---------------------+-------------------------------------------+---------------+
    | Freq. Aquisição     |                  Duração (s)              |   RPM Min¹    |
    |      (Hz)           |                                           |               |
    +---------------------+-------------------------------------------+---------------+
    |                     |                                           |               |
    |       500           |    8.2      16.4      32.8      65.5      |      0.9      |
    |                     |                                           |               |
    |      1000           |    4.1       8.2      16.4      32.8      |      1.8      |
    |                     |                                           |               |
    |      2000           |    2.0       4.1       8.2      16.4      |      3.7      |
    |                     |                                           |               |
    |      4000           |    1.0       2.0       4.1       8.2      |      7.3      |
    |                     |                                           |               |
    |      8000           |    0.5       1.0       2.0       4.1      |     14.6      |
    |                     |                                           |               |
    |     16000           |    0.3       0.5       1.0       2.0      |     29.3      |
    |                     |                                           |               |
    |     32000           |    0.1       0.3       0.5       1.0      |     58.6      |
    |                     |                                           |               |
    +---------------------+-------------------------------------------+---------------+
    |  Número de linhas:      4096      8192     16384     32768                      |
    +---------------------------------------------------------------------------------+

¹RPM calculado considerando um ciclo completo da máquina

**Freq. Aquisição (Hz)**: É a frequência de amostragem usada para capturar os dados de vibração. Valores mais altos (como 32000 Hz) capturam fenômenos de alta frequência.

**Duração (s)**: É o tempo de coleta de dados para cada medição. Existe uma relação inversa com a frequência - quanto maior a frequência de aquisição, menor o tempo necessário para coletar dados suficientes.

**RPM Min¹**: É a rotação mínima da máquina recomendada para cada configuração. À medida que a frequência de aquisição aumenta, a RPM mínima também precisa ser maior.

**Número de linhas**: Representa a resolução espectral (quantidade de pontos de frequência) obtida na análise. Mais linhas significam maior detalhamento do espectro de frequências.

A vibração é coletada nos três eixos: radial, horizontal e vertical.

Para cada frequência de aquisição, existem várias opções de duração. Por exemplo, a 500 Hz você pode escolher entre 8,2s, 16,4s, 32,8s ou 65,5s de medição, cada uma gerando diferentes números de linhas espectrais (4096, 8192, 16384 ou 32768 linhas respectivamente).

    N_amostras = Freq_Aquisição x Duração

A escolha da configuração depende da aplicação: máquinas mais lentas usam frequências menores; análises mais detalhadas exigem mais linhas; e a duração afeta tanto a resolução quanto o tempo total de medição.

É aplicada a Transformada Discreta de Fourier (DFT) nas amostras/sinais antes de serem enviados para os servidores da companhia, utilizando a Transformada Rápida de Fourier (FFT) para economia de pacotes de dados. Como o sinal é real, apenas a parte positiva do espectro da FFT é enviada (aproximadamente metade dos coeficientes, já que a parte negativa é redundante por simetria conjugada). Do lado dos servidores, a simetria conjugada é reconstruída e a FFT inversa é aplicada para converter o sinal de volta para o domínio do tempo, recuperando o sinal original completo com o mesmo número de pontos.

Essas amotras são enviadas a cada 5 minutos por cada sensor. Considerando o caso extremo onde todos os sensores seriam configurados para enviar 32.768,00 linhas teriamos um payload (modelo não exaustivo) parecido com isso

```tsv
r       x       z
0.245   0.312   0.198
0.421   0.389   0.267
0.198   0.278   0.223
0.356   0.445   0.301
0.289   0.334   0.256
0.412   0.401   0.289
0.267   0.298   0.234
0.334   0.367   0.278
0.389   0.456   0.312
0.301   0.323   0.245
0.278   0.389   0.267
0.345   0.412   0.289
0.312   0.356   0.256
0.398   0.434   0.301
0.267   0.312   0.234
0.323   0.378   0.267
0.356   0.423   0.289
0.289   0.345   0.245
0.401   0.467   0.312
0.334   0.389   0.278
...     ...     ...
```

Atualmente existem cerca de 100.000,00 sensores instalados ao redor do mundo.