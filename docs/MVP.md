# Magnife — MVP do app macOS de OpenTelemetry local

Nov 1, 2026 · @Nasser Farhat

## Visão e posicionamento

Um app nativo de macOS que recebe a telemetria OpenTelemetry do que o dev roda na própria máquina e mostra na hora, sem Docker, sem Jaeger e sem conta em fornecedor. A frase de venda: **o Proxyman do OpenTelemetry**.

**O problema.** Instrumentar com OTel localmente hoje exige subir Jaeger, Grafana ou o dashboard do Aspire em Docker, ou usar ferramentas de linha de comando com interface no navegador. As opções existentes são gratuitas e funcionais, mas nenhuma é um app nativo, rápido e bem acabado.

**O que já existe e onde falha:**

| Ferramenta | Formato | Lacuna |
| --- | --- | --- |
| [otel-desktop-viewer](https://github.com/CtrlSpice/otel-desktop-viewer/wiki) | CLI + UI no navegador, open source | Não é nativo; projeto pessoal com cerca de 800 estrelas |
| [otelop](https://github.com/mashiro/otelop) | Binário único + UI no navegador, open source | Em memória, sem persistência; foco em loop rápido |
| [Telemetrix](https://www.nuget.org/packages/Telemetrix) | Biblioteca ASP.NET Core | Só .NET; roda dentro da aplicação |
| [locol](https://whtwnd.com/aparker.io/3ln25vz44372u) | App nativo macOS | Só gerencia o Collector; não visualiza traces |

**Público inicial.** Devs backend e full-stack em Mac que já usam ou estão adotando OpenTelemetry (.NET, Go, Node, Python, Java), e times de startup sem plataforma de observabilidade local.

**Por que pagariam.** O mesmo motivo que sustenta Proxyman, TablePlus e Tower: velocidade, polimento e integração com o Mac, contra alternativas gratuitas mais cruas.

## Escopo do MVP

O MVP faz uma coisa muito bem: receber traces e logs locais e deixar achar o problema em segundos. Métricas, comparação e agentes de IA ficam para as versões seguintes.

**Entra no MVP (v0.1):**

1. **Receptor OTLP embutido** nas portas padrão 4317 (gRPC) e 4318 (HTTP), funcionando ao abrir o app, com um botão que copia as variáveis de ambiente prontas.
2. **Lista de traces** ao vivo, com serviço, rota, duração, status e quantidade de spans.
3. **Waterfall do trace** com detalhe do span: atributos, eventos, exceções com stack trace e recurso de origem.
4. **Logs correlacionados** ao trace e ao span, mais uma aba de logs com filtro por nível e serviço.
5. **Busca e filtros rápidos** por serviço, status, duração mínima e qualquer atributo, com atalho Cmd+K.
6. **Detectores automáticos** que marcam no trace: queries SQL lentas, padrão N+1 (o mesmo statement repetido dentro de um trace) e chamadas HTTP com erro.
7. **Ícone na barra de menu** com contador de erros recentes e notificação nativa quando chega um trace com erro.
8. **Persistência local** com retenção configurável, para os dados sobreviverem ao reinício do app.

**Fica para depois:**

| Versão | Recurso |
| --- | --- |
| v0.2 | Métricas com gráficos; comparação lado a lado de dois traces |
| v0.2 | Exportar e importar traces em arquivo para compartilhar com o time |
| v0.3 | Visão de agentes de IA: chamadas, ferramentas, tokens e custo de Claude Code, Codex e similares |
| v0.3 | Servidor MCP para agentes consultarem os traces locais |
| v0.4 | Encaminhar para um backend remoto (proxy OTLP) |
|  |  |

## Experiência do usuário

A meta é o primeiro trace aparecer em menos de 60 segundos depois de instalar. Tudo que vem antes disso é atrito a eliminar.

**Primeiro uso:**

1. Instala pelo Homebrew (`brew install --cask`) ou pelo site.
2. Abre o app: o receptor já está escutando e a tela vazia mostra as variáveis de ambiente para copiar, com abas por linguagem (.NET, Go, Node, Python, Java).
3. Roda a aplicação e o primeiro trace aparece na lista.

**Janela principal, em três colunas como um app nativo do Mac:**

- **Barra lateral:** serviços detectados, com contagem de erros, mais filtros salvos.
- **Lista central:** traces em tempo real, mais novos no topo, com pausa para congelar a lista enquanto investiga.
- **Painel de detalhe:** waterfall do trace selecionado; ao clicar num span, atributos, logs e exceções daquele span.

**Barra de menu:** um ícone que fica vermelho quando chega erro, com os últimos cinco traces com falha e um clique para abrir direto no detalhe.

**Princípios de design:** atalhos de teclado em tudo, modo escuro nativo, abertura em menos de 1 segundo e nada de Electron.

## Arquitetura técnica

Recomendação para o MVP: interface em SwiftUI e ingestão num processo auxiliar em Go, separados por um banco SQLite local. A interface nunca trava com volume alto, e o protocolo OTLP vem pronto do Collector oficial.

&#91;embedded content: arquitetura · 5 componentes\]

O helper grava os spans em lote e avisa o app por um socket local; o app só consulta o banco e redesenha.

| Camada | Escolha | Por quê |
| --- | --- | --- |
| Interface | SwiftUI, com AppKit na lista de traces se precisar de desempenho | Nativo, rápido, modo escuro e atalhos de graça |
| Ingestão | Go, reaproveitando o receptor OTLP do OpenTelemetry Collector | Compatibilidade total do protocolo (gRPC, HTTP, protobuf, JSON, gzip) e você já domina Go |
| Banco | SQLite em modo WAL, lido pelo app com GRDB | Um arquivo, leitura e escrita concorrentes, consultas e índices simples |
| Processo | Helper iniciado e encerrado pelo próprio app | Sem serviço residente nem instalação extra |
| Atualização | Sparkle | Padrão para apps distribuídos fora da App Store |

**Alternativa:** tudo em Swift, com swift-protobuf e grpc-swift. Menos peças no pacote, mas exige reimplementar o receptor OTLP. Vale reavaliar depois do MVP, se o binário em Go pesar no tamanho do app.

## Distribuição, preço e licenciamento

> **Decidido em 2026-11-05:** o Magnife é open source (MIT), o app inteiro, sem plano pago. Os planos Free/Pro e a cobrança abaixo ficam só como registro da hipótese original; a distribuição (Developer ID, notarização, Sparkle, Homebrew) continua valendo.

Vender fora da Mac App Store, com versão gratuita útil e licença Pro paga. Os valores abaixo são hipóteses a validar com os primeiros usuários.

**Distribuição:**

- Assinatura com Developer ID e notarização da Apple, atualizações automáticas pelo Sparkle.
- Homebrew cask desde o primeiro dia, porque é onde o dev procura ferramenta.
- Fora da App Store no início: o sandbox complica escutar portas e rodar processo auxiliar. Reavaliar depois.

**Cobrança:** um merchant of record como Paddle ou Lemon Squeezy, que cuida de imposto sobre venda nos EUA e no exterior e emite a licença. Evita abrir estrutura fiscal americana só para vender o app.

**Planos (hipótese):**

| Plano | Inclui | Preço a testar |
| --- | --- | --- |
| Free | Traces e logs, retenção de 1 hora, 2 serviços | Grátis |
| Pro | Retenção configurável, serviços ilimitados, detectores, filtros salvos, barra de menu | Licença única de US$ 49 a 79 com 1 ano de atualizações, ou US$ 6 a 8 por mês |
| Team (depois) | Licenças por volume e compartilhamento de traces | Por assento |

O limite do Free precisa deixar o dev sentir o valor em uso real e esbarrar na limitação depois de alguns dias, não no primeiro minuto.

## Plano de 8 semanas

Oito semanas de trabalho dedicado levam do receptor ao lançamento público, com um gate antes de abrir para todos. Em meio período, conte o dobro.

&#91;embedded content: plano de 8 semanas · 5 fases, 1 gate\]

Se o gate falhar, a semana 8 vira mais uma rodada de onboarding antes do lançamento.

## Lançamento e métricas de validação

O lançamento mira onde quem já usa OpenTelemetry conversa, e o sucesso se mede por ativação e conversão, não por downloads.

**Canais:**

- Show HN no Hacker News, com um GIF de 20 segundos do primeiro trace aparecendo.
- Comunidades de OpenTelemetry e de .NET Aspire, e subreddits como r/opentelemetry, r/dotnet, r/golang e r/macapps.
- Product Hunt, depois de ter os primeiros usuários e depoimentos.
- Tutoriais curtos: "veja os traces da sua API .NET/Go/Node em 1 minuto", que também trazem busca orgânica.

**Métricas, em ordem de importância:**

| Métrica | O que mede | Sinal de que vale continuar |
| --- | --- | --- |
| Ativação | % de instalações que recebem o primeiro trace | Acima de 50% |
| Retenção semanal | % que volta a abrir na segunda semana | Acima de 30% |
| Conversão | % de usuários ativos que compram o Pro | Acima de 3% |
| Pedidos espontâneos | Usuários pedindo recursos ou reportando bugs | Qualquer volume constante |

Esses limites são referências para decidir, não números garantidos do mercado. A telemetria do próprio app deve ser opcional e anônima, porque esse público rejeita rastreamento escondido.

## Riscos e decisões em aberto

O maior risco é de negócio, não técnico: dev resiste a pagar quando há alternativa gratuita.

**Riscos:**

| Risco | Mitigação |
| --- | --- |
| Ferramentas gratuitas bastam para a maioria | Vender velocidade e polimento; Free generoso; detectores e barra de menu só no Pro |
| Um fornecedor grande lança app desktop gratuito | Lançar rápido e construir a comunidade antes; manter o foco em experiência nativa |
| Volume alto de spans trava a interface | Ingestão fora da thread principal, paginação e limite de retenção por padrão |
| Público pequeno (só quem já usa OTel no Mac) | A visão de agentes de IA na v0.3 amplia para todo dev que usa Claude Code ou Codex |

**Decisões em aberto:**

- [x] Ingestão em Swift puro ou processo auxiliar em Go (ver Arquitetura): processo auxiliar em Go
- [x] Licença única ou assinatura: nenhuma das duas; open source sem plano pago (2026-11-05)
- [ ] Domínio, handles e busca de marca no USPTO para o nome Magnife
- [x] Código aberto do receptor, para ganhar confiança, mantendo o app fechado: o app inteiro é open source, MIT (2026-11-05)
