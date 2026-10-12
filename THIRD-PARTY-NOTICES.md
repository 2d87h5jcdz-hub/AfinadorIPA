# Componentes de terceiros

O Pestana Estúdio usa estes projetos de código aberto. As licenças originais acompanham o código em `Vendor/`.

| Componente | Uso no app | Licença |
|---|---|---|
| [NeuralAmpModelerCore](https://github.com/sdatkinson/NeuralAmpModelerCore) | Amplificador com IA (modelos .nam) | MIT — `Vendor/NAM/LICENSE` |
| [Eigen](https://eigen.tuxfamily.org) 3.4 | Álgebra linear do NeuralAmpModelerCore | MPL 2.0 — `Vendor/eigen/COPYING.MPL2` |
| [nlohmann/json](https://github.com/nlohmann/json) | Leitura dos arquivos .nam | MIT |
| [Demucs](https://github.com/facebookresearch/demucs) (htdemucs_6s) | Separação de instrumentos no Treino (convertido para Core ML) | MIT |

Os modelos .nam que o usuário importa (por exemplo, do tone3000.com) pertencem aos seus autores e seguem as licenças de cada um; eles não são distribuídos com o app.
