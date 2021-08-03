{
  _config+:: {
    kubeApiserverSelector: 'job="kube-apiserver"',
    podLabel: 'pod',
    kubeApiserverReadSelector: 'verb=~"LIST|GET"',
    kubeApiserverWriteSelector: 'verb=~"POST|PUT|PATCH|DELETE"',
    // These are buckets that exist on the apiserver_request_duration_seconds_bucket histogram.
    // They are what the Kubernetes SIG Scalability is using to measure availability of Kubernetes clusters.
    // If you want to change these, make sure the "le" buckets exist on the histogram!
    kubeApiserverReadResourceLatency: '1',
    kubeApiserverReadNamespaceLatency: '5',
    kubeApiserverReadClusterLatency: '40',  // 30 doesn't exist as a bucket and thus it's 40
    kubeApiserverWriteLatency: '1',
  },

  prometheusRules+:: {
    local SLODays = $._config.SLOs.apiserver.days + 'd',
    local SLOTarget = $._config.SLOs.apiserver.target,
    local verbs = [
      { type: 'read', selector: $._config.kubeApiserverReadSelector },
      { type: 'write', selector: $._config.kubeApiserverWriteSelector },
    ],

    groups+: [
      {
        name: 'kube-apiserver-burnrate.rules',
        rules: [
          {
            record: 'apiserver_request:burnrate%(window)s' % w,
            expr: |||
              (
                (
                  # too slow
                  sum by (%(clusterLabel)s) (rate(apiserver_request_duration_seconds_count{%(kubeApiserverSelector)s,%(kubeApiserverReadSelector)s}[%(window)s]))
                  -
                  (
                    (
                      sum by (%(clusterLabel)s) (rate(apiserver_request_duration_seconds_bucket{%(kubeApiserverSelector)s,%(kubeApiserverReadSelector)s,scope=~"resource|",le="%(kubeApiserverReadResourceLatency)s"}[%(window)s]))
                      or
                      vector(0)
                    )
                    +
                    sum by (%(clusterLabel)s) (rate(apiserver_request_duration_seconds_bucket{%(kubeApiserverSelector)s,%(kubeApiserverReadSelector)s,scope="namespace",le="%(kubeApiserverReadNamespaceLatency)s"}[%(window)s]))
                    +
                    sum by (%(clusterLabel)s) (rate(apiserver_request_duration_seconds_bucket{%(kubeApiserverSelector)s,%(kubeApiserverReadSelector)s,scope="cluster",le="%(kubeApiserverReadClusterLatency)s"}[%(window)s]))
                  )
                )
                +
                # errors
                sum by (%(clusterLabel)s) (rate(apiserver_request_total{%(kubeApiserverSelector)s,%(kubeApiserverReadSelector)s,code=~"5.."}[%(window)s]))
              )
              /
              sum by (%(clusterLabel)s) (rate(apiserver_request_total{%(kubeApiserverSelector)s,%(kubeApiserverReadSelector)s}[%(window)s]))
            ||| % {
              clusterLabel: $._config.clusterLabel,
              window: w,
              kubeApiserverSelector: $._config.kubeApiserverSelector,
              kubeApiserverReadSelector: $._config.kubeApiserverReadSelector,
              kubeApiserverReadResourceLatency: $._config.kubeApiserverReadResourceLatency,
              kubeApiserverReadNamespaceLatency: $._config.kubeApiserverReadNamespaceLatency,
              kubeApiserverReadClusterLatency: $._config.kubeApiserverReadClusterLatency,
            },
            labels: {
              verb: 'read',
            },
          }
          for w in std.set([  // Get the unique array of short and long window rates
            w.short
            for w in $._config.SLOs.apiserver.windows
          ] + [
            w.long
            for w in $._config.SLOs.apiserver.windows
          ])
        ] + [
          {
            record: 'apiserver_request:burnrate%(window)s' % w,
            expr: |||
              (
                (
                  # too slow
                  sum by (%(clusterLabel)s) (rate(apiserver_request_duration_seconds_count{%(kubeApiserverSelector)s,%(kubeApiserverWriteSelector)s}[%(window)s]))
                  -
                  sum by (%(clusterLabel)s) (rate(apiserver_request_duration_seconds_bucket{%(kubeApiserverSelector)s,%(kubeApiserverWriteSelector)s,le="%(kubeApiserverWriteLatency)s"}[%(window)s]))
                )
                +
                sum by (%(clusterLabel)s) (rate(apiserver_request_total{%(kubeApiserverSelector)s,%(kubeApiserverWriteSelector)s,code=~"5.."}[%(window)s]))
              )
              /
              sum by (%(clusterLabel)s) (rate(apiserver_request_total{%(kubeApiserverSelector)s,%(kubeApiserverWriteSelector)s}[%(window)s]))
            ||| % {
              clusterLabel: $._config.clusterLabel,
              window: w,
              kubeApiserverSelector: $._config.kubeApiserverSelector,
              kubeApiserverWriteSelector: $._config.kubeApiserverWriteSelector,
              kubeApiserverWriteLatency: $._config.kubeApiserverWriteLatency,
            },
            labels: {
              verb: 'write',
            },
          }
          for w in std.set([  // Get the unique array of short and long window rates
            w.short
            for w in $._config.SLOs.apiserver.windows
          ] + [
            w.long
            for w in $._config.SLOs.apiserver.windows
          ])
        ],
      },
      {
        name: 'kube-apiserver-histogram.rules',
        rules:
          [
            {
              record: 'cluster_quantile:apiserver_request_duration_seconds:histogram_quantile',
              expr: |||
                histogram_quantile(0.99, sum by (%s, le, resource) (rate(apiserver_request_duration_seconds_bucket{%s}[5m]))) > 0
              ||| % [$._config.clusterLabel, std.join(',', [$._config.kubeApiserverSelector, verb.selector])],
              labels: {
                verb: verb.type,
                quantile: '0.99',
              },
            }
            for verb in verbs
          ] + [
            {
              record: 'cluster_quantile:apiserver_request_duration_seconds:histogram_quantile',
              expr: |||
                histogram_quantile(%(quantile)s, sum(rate(apiserver_request_duration_seconds_bucket{%(kubeApiserverSelector)s,subresource!="log",verb!~"LIST|WATCH|WATCHLIST|DELETECOLLECTION|PROXY|CONNECT"}[5m])) without(instance, %(podLabel)s))
              ||| % ({ quantile: quantile } + $._config),
              labels: {
                quantile: quantile,
              },
            }
            for quantile in ['0.99', '0.9', '0.5']
          ],
      },
      {
        name: 'kube-apiserver-availability.rules',
        interval: '3m',
        rules: [
          {
            record: 'code_verb:apiserver_request_total:increase%s' % SLODays,
            expr: |||
              avg_over_time(code_verb:apiserver_request_total:increase1h[%s]) * 24 * %d
            ||| % [SLODays, $._config.SLOs.apiserver.days],
          },
        ] + [
          {
            record: 'code:apiserver_request_total:increase%s' % SLODays,
            expr: |||
              sum by (%s, code) (code_verb:apiserver_request_total:increase%s{%s})
            ||| % [$._config.clusterLabel, SLODays, verb.selector],
            labels: {
              verb: verb.type,
            },
          }
          for verb in verbs
        ] + [
          {
            record: 'cluster_verb_scope:apiserver_request_duration_seconds_count:increase1h',
            expr: |||
              sum by (%(clusterLabel)s, verb, scope) (increase(apiserver_request_duration_seconds_count[1h]))
            ||| % $._config,
          },
          {
            record: 'cluster_verb_scope_le:apiserver_request_duration_seconds_bucket:increase1h',
            expr: |||
              sum by (%(clusterLabel)s, verb, scope, le) (increase(apiserver_request_duration_seconds_bucket[1h]))
            ||| % $._config,
          },
          {
            record: 'apiserver_request:availability%s' % SLODays,
            expr: |||
              1 - (
                (
                  # write too slow
                  sum by (%(clusterLabel)s) (avg_over_time(cluster_verb_scope:apiserver_request_duration_seconds_count:increase1h{%(kubeApiserverWriteSelector)s}[%(SLODays)s]) * 24 * %(days)s)
                  -
                  sum by (%(clusterLabel)s) (avg_over_time(cluster_verb_scope_le:apiserver_request_duration_seconds_bucket:increase1h{%(kubeApiserverWriteSelector)s,le="%(kubeApiserverWriteLatency)s"}[%(SLODays)s]) * 24 * %(days)s)
                ) +
                (
                  # read too slow
                  sum by (%(clusterLabel)s) (avg_over_time(cluster_verb_scope:apiserver_request_duration_seconds_count:increase1h{%(kubeApiserverReadSelector)s}[%(SLODays)s]) * 24 * %(days)s)
                  -
                  (
                    (
                      sum by (%(clusterLabel)s) (avg_over_time(cluster_verb_scope_le:apiserver_request_duration_seconds_bucket:increase1h{%(kubeApiserverReadSelector)s,scope=~"resource|",le="%(kubeApiserverReadResourceLatency)s"}[%(SLODays)s]) * 24 * %(days)s)
                      or
                      vector(0)
                    )
                    +
                    sum by (%(clusterLabel)s) (avg_over_time(cluster_verb_scope_le:apiserver_request_duration_seconds_bucket:increase1h{%(kubeApiserverReadSelector)s,scope="namespace",le="%(kubeApiserverReadNamespaceLatency)s"}[%(SLODays)s]) * 24 * %(days)s)
                    +
                    sum by (%(clusterLabel)s) (avg_over_time(cluster_verb_scope_le:apiserver_request_duration_seconds_bucket:increase1h{%(kubeApiserverReadSelector)s,scope="cluster",le="%(kubeApiserverReadClusterLatency)s"}[%(SLODays)s]) * 24 * %(days)s)
                  )
                ) +
                # errors
                sum by (%(clusterLabel)s) (code:apiserver_request_total:increase%(SLODays)s{code=~"5.."} or vector(0))
              )
              /
              sum by (%(clusterLabel)s) (code:apiserver_request_total:increase%(SLODays)s)
            ||| % ($._config { SLODays: SLODays, days: $._config.SLOs.apiserver.days }),
            labels: {
              verb: 'all',
            },
          },
          {
            record: 'apiserver_request:availability%s' % SLODays,
            expr: |||
              1 - (
                sum by (%(clusterLabel)s) (avg_over_time(cluster_verb_scope:apiserver_request_duration_seconds_count:increase1h{%(kubeApiserverReadSelector)s}[%(SLODays)s]) * 24 * %(days)s)
                -
                (
                  # too slow
                  (
                    sum by (%(clusterLabel)s) (avg_over_time(cluster_verb_scope_le:apiserver_request_duration_seconds_bucket:increase1h{%(kubeApiserverReadSelector)s,scope=~"resource|",le="%(kubeApiserverReadResourceLatency)s"}[%(SLODays)s]) * 24 * %(days)s)
                    or
                    vector(0)
                  )
                  +
                  sum by (%(clusterLabel)s) (avg_over_time(cluster_verb_scope_le:apiserver_request_duration_seconds_bucket:increase1h{%(kubeApiserverReadSelector)s,scope="namespace",le="%(kubeApiserverReadNamespaceLatency)s"}[%(SLODays)s]) * 24 * %(days)s)
                  +
                  sum by (%(clusterLabel)s) (avg_over_time(cluster_verb_scope_le:apiserver_request_duration_seconds_bucket:increase1h{%(kubeApiserverReadSelector)s,scope="cluster",le="%(kubeApiserverReadClusterLatency)s"}[%(SLODays)s]) * 24 * %(days)s)
                )
                +
                # errors
                sum by (%(clusterLabel)s) (code:apiserver_request_total:increase%(SLODays)s{verb="read",code=~"5.."} or vector(0))
              )
              /
              sum by (%(clusterLabel)s) (code:apiserver_request_total:increase%(SLODays)s{verb="read"})
            ||| % ($._config { SLODays: SLODays, days: $._config.SLOs.apiserver.days }),
            labels: {
              verb: 'read',
            },
          },
          {
            record: 'apiserver_request:availability%s' % SLODays,
            expr: |||
              1 - (
                (
                  # too slow
                  sum by (%(clusterLabel)s) (avg_over_time(cluster_verb_scope:apiserver_request_duration_seconds_count:increase1h{%(kubeApiserverWriteSelector)s}[%(SLODays)s]) * 24 * %(days)s)
                  -
                  sum by (%(clusterLabel)s) (avg_over_time(cluster_verb_scope_le:apiserver_request_duration_seconds_bucket:increase1h{%(kubeApiserverWriteSelector)s,le="%(kubeApiserverWriteLatency)s"}[%(SLODays)s]) * 24 * %(days)s)
                )
                +
                # errors
                sum by (%(clusterLabel)s) (code:apiserver_request_total:increase%(SLODays)s{verb="write",code=~"5.."} or vector(0))
              )
              /
              sum by (%(clusterLabel)s) (code:apiserver_request_total:increase%(SLODays)s{verb="write"})
            ||| % ($._config { SLODays: SLODays, days: $._config.SLOs.apiserver.days }),
            labels: {
              verb: 'write',
            },
          },
        ] + [
          {
            record: 'code_resource:apiserver_request_total:rate5m',
            expr: |||
              sum by (%s,code,resource) (rate(apiserver_request_total{%s}[5m]))
            ||| % [$._config.clusterLabel, std.join(',', [$._config.kubeApiserverSelector, verb.selector])],
            labels: {
              verb: verb.type,
            },
          }
          for verb in verbs
        ] + [
          {
            record: 'code_verb:apiserver_request_total:increase1h',
            expr: |||
              sum by (%s, code, verb) (increase(apiserver_request_total{%s,verb=~"LIST|GET|POST|PUT|PATCH|DELETE",code=~"%s"}[1h]))
            ||| % [$._config.clusterLabel, $._config.kubeApiserverSelector, code],
          }
          for code in ['2..', '3..', '4..', '5..']
        ],
      },
    ],
  },
}
