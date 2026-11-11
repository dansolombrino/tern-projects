-- Real capture: cx.session:surface(pane, {as = "table"}) of an omp 18.18.8 agent block in Tern 0.9.16
-- (2026-11-11), encoded with tern.json.encode(tree, true). The JSON below is verbatim.
return [==[
{
  "main": {
    "c": [
      {
        "id": "o",
        "k": "spacer",
        "p": {
          "size": "sm"
        }
      },
      {
        "c": [
          {
            "c": [
              {
                "id": "1.lockup/logo",
                "k": "image",
                "p": {
                  "alt": "omp",
                  "builtin": "omp",
                  "role": "omp.welcome.logo",
                  "w": 128
                }
              },
              {
                "c": [
                  {
                    "id": "1.lockup/mark/omp.welcome.wordmark",
                    "k": "text",
                    "p": {
                      "role": "omp.welcome.wordmark",
                      "spans": [
                        {
                          "s": "strong",
                          "t": "omp"
                        }
                      ],
                      "wrap": "none"
                    }
                  },
                  {
                    "id": "1.lockup/mark/omp.welcome.version",
                    "k": "text",
                    "p": {
                      "role": "omp.welcome.version",
                      "spans": [
                        {
                          "s": "dim mono",
                          "t": "v18.18.8"
                        }
                      ],
                      "wrap": "none"
                    }
                  }
                ],
                "id": "1.lockup/mark",
                "k": "col",
                "p": {
                  "role": "omp.welcome.mark"
                }
              }
            ],
            "id": "1.lockup",
            "k": "row",
            "p": {
              "align": "center",
              "gap": "md",
              "role": "omp.welcome.lockup"
            }
          },
          {
            "c": [
              {
                "id": "1.tip/0",
                "k": "icon",
                "p": {
                  "name": "lightbulb",
                  "role": "omp.welcome.tip-icon"
                }
              },
              {
                "id": "1.tip/1",
                "k": "text",
                "p": {
                  "role": "omp.welcome.tip-text",
                  "text": "Find out which model you emotionally abuse the most with `omp stats`",
                  "wrap": "word"
                }
              }
            ],
            "id": "1.tip",
            "k": "row",
            "p": {
              "align": "start",
              "gap": "sm",
              "role": "omp.welcome.tip"
            }
          }
        ],
        "id": "1",
        "k": "card",
        "p": {
          "role": "omp.welcome"
        }
      },
      {
        "id": "p",
        "k": "spacer",
        "p": {
          "size": "sm"
        }
      },
      {
        "c": [
          {
            "c": [
              {
                "id": "r.tools/copy",
                "k": "icon",
                "p": {
                  "actions": {
                    "click": "copy-message"
                  },
                  "aria": "Copy message",
                  "name": "copy",
                  "role": "omp.user.tool",
                  "title": "Copy message"
                }
              },
              {
                "id": "r.tools/rewind",
                "k": "icon",
                "p": {
                  "actions": {
                    "click": "rewind"
                  },
                  "aria": "Rewind",
                  "name": "rewind",
                  "role": "omp.user.tool",
                  "title": "Rewind the conversation to an earlier message"
                }
              },
              {
                "id": "r.tools/dot",
                "k": "text",
                "p": {
                  "text": "·"
                }
              },
              {
                "id": "r.tools/3",
                "k": "text",
                "p": {
                  "role": "omp.user.time",
                  "spans": [
                    {
                      "s": "dim mono",
                      "t": "09:23"
                    }
                  ],
                  "title": "11/11/2026, 09:23:56"
                }
              }
            ],
            "id": "r.tools",
            "k": "row",
            "p": {
              "align": "center",
              "gap": "xs",
              "role": "omp.user.tools"
            }
          },
          {
            "id": "r.1",
            "k": "md",
            "p": {
              "text": "Use your task tool once to run exactly 2 subagents in parallel. Subagent Alpha: run the bash command `sleep 20`, then reply alpha. Subagent Beta: use your own task tool to spawn one subagent named Gamma that runs `sleep 10` in bash and replies gamma; then reply beta. Do nothing else. Then reply done."
            }
          }
        ],
        "id": "r",
        "k": "card",
        "p": {
          "actions": {
            "hold": [
              {
                "icon": "copy",
                "id": "copy-message",
                "label": "Copy message"
              },
              {
                "detail": "To composer",
                "icon": "edit",
                "id": "edit-turn",
                "label": "Edit & resend"
              },
              {
                "icon": "refresh",
                "id": "retry-turn",
                "label": "Retry turn"
              },
              {
                "icon": "rewind",
                "id": "rewind-turn",
                "label": "Rewind to here…"
              },
              {
                "detail": "New session",
                "icon": "branch",
                "id": "fork-turn",
                "label": "Fork from here"
              }
            ]
          },
          "role": "omp.user",
          "tone": "user"
        }
      },
      {
        "id": "w",
        "k": "col",
        "p": {
          "hidden": true
        }
      },
      {
        "id": "y",
        "k": "col",
        "p": {
          "role": "omp.assistant"
        }
      },
      {
        "c": [
          {
            "id": "z.0",
            "k": "text",
            "p": {
              "lines": 2,
              "role": "omp.tool.context",
              "spans": [
                {
                  "s": "muted",
                  "t": "# Goal Simple orchestration probe. Do exactly what the task says, nothing else."
                }
              ],
              "wrap": "word"
            }
          },
          {
            "c": [
              {
                "id": "z.Beta/0",
                "k": "md",
                "p": {
                  "role": "omp.task.assignment",
                  "text": "# Target\nNo files.\n# Change\nUse your own task tool to spawn exactly one subagent named Gamma with this task: \"Run the bash command `sleep 10` (timeout at least 20s). Do nothing else. Then reply with exactly: gamma\". Wait for Gamma to finish. Do nothing else.\n# Acceptance\nAfter Gamma completes, reply with exactly: beta"
                }
              },
              {
                "c": [
                  {
                    "id": "z.Beta/Beta.Gamma/0",
                    "k": "md",
                    "p": {
                      "role": "omp.task.assignment",
                      "text": "Run the bash command `sleep 10` (timeout at least 20s). Do nothing else. Then reply with exactly: gamma"
                    }
                  }
                ],
                "id": "z.Beta/Beta.Gamma",
                "k": "agent",
                "p": {
                  "agent": "task",
                  "badges": [
                    {
                      "text": "background"
                    }
                  ],
                  "collapsed": true,
                  "collapsible": true,
                  "depth": 1,
                  "hovercard": {
                    "k": "md",
                    "p": {
                      "role": "omp.task.assignment",
                      "text": "Run the bash command `sleep 10` (timeout at least 20s). Do nothing else. Then reply with exactly: gamma"
                    }
                  },
                  "name": "Beta>Gamma",
                  "stats": {
                    "took": 0
                  },
                  "status": "pending",
                  "task": "Run the bash command `sleep 10` (timeout at least 20s). Do nothing else. Then reply with exactly: gamma"
                }
              }
            ],
            "id": "z.Beta",
            "k": "agent",
            "p": {
              "agent": "task",
              "badges": [
                {
                  "text": "background"
                }
              ],
              "collapsed": true,
              "collapsible": true,
              "hovercard": {
                "k": "md",
                "p": {
                  "role": "omp.task.assignment",
                  "text": "# Target\nNo files.\n# Change\nUse your own task tool to spawn exactly one subagent named Gamma with this task: \"Run the bash command `sleep 10` (timeout at least 20s). Do nothing else. Then reply with exactly: gamma\". Wait for Gamma to finish. Do nothing else.\n# Acceptance\nAfter Gamma completes, reply with exactly: beta"
                }
              },
              "model": "anthropic/claude-opus-5-5",
              "name": "Beta",
              "stats": {
                "context": 0.03971,
                "contextLabel": "40K / 1M",
                "cost": 0.12090559999999999,
                "requests": 4,
                "tokens": 10961,
                "took": 16897,
                "tools": 3
              },
              "status": "done",
              "task": "# Target No files. # Change Use your own task tool to spawn exactly one subagent named Gamma with this task: \"Run the bash command `sleep 10` (timeout at least 20s). Do nothing else. Then reply with exactly: gamma\". Wait for Gamma to finish. Do nothing else. # Acceptance After Gamma completes, reply with exactly: beta",
              "thinking": "thinkingMedium"
            }
          },
          {
            "c": [
              {
                "id": "z.Alpha/0",
                "k": "md",
                "p": {
                  "role": "omp.task.assignment",
                  "text": "# Target\nNo files.\n# Change\nRun the bash command `sleep 20` (use timeout of at least 30s). Do nothing else.\n# Acceptance\nAfter the command finishes, reply with exactly: alpha"
                }
              }
            ],
            "id": "z.Alpha",
            "k": "agent",
            "p": {
              "agent": "task",
              "badges": [
                {
                  "text": "background"
                }
              ],
              "collapsed": true,
              "collapsible": true,
              "hovercard": {
                "k": "md",
                "p": {
                  "role": "omp.task.assignment",
                  "text": "# Target\nNo files.\n# Change\nRun the bash command `sleep 20` (use timeout of at least 30s). Do nothing else.\n# Acceptance\nAfter the command finishes, reply with exactly: alpha"
                }
              },
              "model": "anthropic/claude-opus-5-5",
              "name": "Alpha",
              "stats": {
                "age": 16823,
                "context": 0.039135,
                "contextLabel": "39K / 1M",
                "cost": 0.087539,
                "requests": 1,
                "tokens": 10060,
                "tools": 1
              },
              "status": "running",
              "task": "# Target No files. # Change Run the bash command `sleep 20` (use timeout of at least 30s). Do nothing else. # Acceptance After the command finishes, reply with exactly: alpha",
              "thinking": "thinkingMedium",
              "tool": {
                "age": 15319,
                "intent": "Sleeping 20 seconds",
                "name": "bash"
              }
            }
          }
        ],
        "id": "z",
        "k": "tool",
        "p": {
          "age": 16944,
          "badges": [
            {
              "text": "background"
            }
          ],
          "collapsed": true,
          "collapsible": true,
          "frame": "card",
          "intent": "Spawning Alpha and Beta subagents",
          "key": "toolu_01UQCyuWy1wSK1o27bkuUpBT",
          "name": "task",
          "preview": "none",
          "role": "omp.tool.task",
          "status": "running",
          "target": "2 agents",
          "targetKind": "text",
          "title": "Task"
        }
      },
      {
        "c": [
          {
            "id": "10.0",
            "k": "text",
            "p": {
              "spans": [
                {
                  "s": "dim",
                  "t": "09:23 · Δ 5.7s · in 9.3K · out 424 · cache 33K · ttft 1.1s"
                }
              ]
            }
          },
          {
            "id": "10.1",
            "k": "text",
            "p": {
              "spans": [
                {
                  "s": "dim",
                  "t": " · "
                }
              ]
            }
          },
          {
            "id": "10.2",
            "k": "rate",
            "p": {
              "unit": "tok/s",
              "value": 99.4
            }
          }
        ],
        "id": "10",
        "k": "row",
        "p": {
          "align": "baseline",
          "gap": "none",
          "role": "omp.usage.turn",
          "title": "2026-11-11 09:23:58"
        }
      },
      {
        "id": "11",
        "k": "col",
        "p": {
          "role": "omp.assistant"
        }
      },
      {
        "c": [
          {
            "c": [
              {
                "c": [
                  {
                    "c": [
                      {
                        "id": "12.tiles/cnl99j7f7zt5/head/0",
                        "k": "text",
                        "p": {
                          "role": "omp.job.tile.dot",
                          "spans": [
                            {
                              "s": "accent",
                              "t": "●"
                            }
                          ],
                          "wrap": "none"
                        }
                      },
                      {
                        "id": "12.tiles/cnl99j7f7zt5/head/1",
                        "k": "text",
                        "p": {
                          "grow": 1,
                          "role": "omp.job.tile.title",
                          "spans": [
                            {
                              "t": "Alpha"
                            }
                          ],
                          "truncate": "end",
                          "wrap": "none"
                        }
                      },
                      {
                        "id": "12.tiles/cnl99j7f7zt5/head/clock",
                        "k": "elapsed",
                        "p": {
                          "age": 6097,
                          "format": "short",
                          "stopped": 6097
                        }
                      }
                    ],
                    "id": "12.tiles/cnl99j7f7zt5/head",
                    "k": "row",
                    "p": {
                      "align": "center",
                      "gap": "xs",
                      "role": "omp.job.tile.head"
                    }
                  }
                ],
                "id": "12.tiles/cnl99j7f7zt5",
                "k": "col",
                "p": {
                  "gap": "xs",
                  "role": "omp.job.tile",
                  "tone": "accent"
                }
              },
              {
                "c": [
                  {
                    "c": [
                      {
                        "id": "12.tiles/346j31umkelau/head/0",
                        "k": "text",
                        "p": {
                          "role": "omp.job.tile.dot",
                          "spans": [
                            {
                              "s": "accent",
                              "t": "●"
                            }
                          ],
                          "wrap": "none"
                        }
                      },
                      {
                        "id": "12.tiles/346j31umkelau/head/1",
                        "k": "text",
                        "p": {
                          "grow": 1,
                          "role": "omp.job.tile.title",
                          "spans": [
                            {
                              "t": "Beta"
                            }
                          ],
                          "truncate": "end",
                          "wrap": "none"
                        }
                      },
                      {
                        "id": "12.tiles/346j31umkelau/head/clock",
                        "k": "elapsed",
                        "p": {
                          "age": 6096,
                          "format": "short",
                          "stopped": 6096
                        }
                      }
                    ],
                    "id": "12.tiles/346j31umkelau/head",
                    "k": "row",
                    "p": {
                      "align": "center",
                      "gap": "xs",
                      "role": "omp.job.tile.head"
                    }
                  }
                ],
                "id": "12.tiles/346j31umkelau",
                "k": "col",
                "p": {
                  "gap": "xs",
                  "role": "omp.job.tile",
                  "tone": "accent"
                }
              }
            ],
            "id": "12.tiles",
            "k": "row",
            "p": {
              "gap": "none",
              "role": "omp.job.tiles",
              "wrap": true
            }
          }
        ],
        "id": "12",
        "k": "tool",
        "p": {
          "collapsed": true,
          "collapsible": true,
          "frame": "card",
          "intent": "Waiting for subagents",
          "key": "toolu_019AcRiry6tsRedDPwfVBKuG",
          "name": "wait",
          "preview": "children",
          "role": "omp.tool.wait",
          "status": "done",
          "title": [
            {
              "s": "toolTitle strong",
              "t": "waiting on 2 jobs"
            }
          ],
          "tone": "info",
          "took": 5007
        }
      },
      {
        "c": [
          {
            "id": "13.0",
            "k": "text",
            "p": {
              "spans": [
                {
                  "s": "dim",
                  "t": "09:24 · Δ 6.8s · in 617 · out 54 · cache 42K · ttft 0.8s"
                }
              ]
            }
          },
          {
            "id": "13.1",
            "k": "text",
            "p": {
              "spans": [
                {
                  "s": "dim",
                  "t": " · "
                }
              ]
            }
          },
          {
            "id": "13.2",
            "k": "rate",
            "p": {
              "unit": "tok/s",
              "value": 50
            }
          }
        ],
        "id": "13",
        "k": "row",
        "p": {
          "align": "baseline",
          "gap": "none",
          "role": "omp.usage.turn",
          "title": "2026-11-11 09:24:02"
        }
      },
      {
        "id": "14",
        "k": "col",
        "p": {
          "role": "omp.assistant"
        }
      },
      {
        "c": [
          {
            "c": [
              {
                "c": [
                  {
                    "c": [
                      {
                        "id": "15.tiles/cnl99j7f7zt5/head/0",
                        "k": "text",
                        "p": {
                          "role": "omp.job.tile.dot",
                          "spans": [
                            {
                              "s": "accent",
                              "t": "●"
                            }
                          ],
                          "wrap": "none"
                        }
                      },
                      {
                        "id": "15.tiles/cnl99j7f7zt5/head/1",
                        "k": "text",
                        "p": {
                          "grow": 1,
                          "role": "omp.job.tile.title",
                          "spans": [
                            {
                              "t": "Alpha"
                            }
                          ],
                          "truncate": "end",
                          "wrap": "none"
                        }
                      },
                      {
                        "id": "15.tiles/cnl99j7f7zt5/head/clock",
                        "k": "elapsed",
                        "p": {
                          "age": 18128,
                          "format": "short",
                          "stopped": 18128
                        }
                      }
                    ],
                    "id": "15.tiles/cnl99j7f7zt5/head",
                    "k": "row",
                    "p": {
                      "align": "center",
                      "gap": "xs",
                      "role": "omp.job.tile.head"
                    }
                  }
                ],
                "id": "15.tiles/cnl99j7f7zt5",
                "k": "col",
                "p": {
                  "gap": "xs",
                  "role": "omp.job.tile",
                  "tone": "accent"
                }
              },
              {
                "c": [
                  {
                    "id": "15.tiles/346j31umkelau/head",
                    "k": "row",
                    "more": 3,
                    "p": {
                      "align": "center",
                      "gap": "xs",
                      "role": "omp.job.tile.head"
                    }
                  }
                ],
                "id": "15.tiles/346j31umkelau",
                "k": "col",
                "p": {
                  "gap": "xs",
                  "role": "omp.job.tile",
                  "tone": "success"
                }
              }
            ],
            "id": "15.tiles",
            "k": "row",
            "p": {
              "gap": "none",
              "role": "omp.job.tiles",
              "wrap": true
            }
          }
        ],
        "id": "15",
        "k": "tool",
        "p": {
          "collapsed": true,
          "collapsible": true,
          "frame": "card",
          "intent": "Waiting for subagents",
          "key": "toolu_01LosBuvkQReutcnvxDnqkmK",
          "name": "wait",
          "preview": "children",
          "role": "omp.tool.wait",
          "status": "done",
          "title": [
            {
              "s": "toolTitle strong",
              "t": "waiting on 1 of 2 jobs"
            },
            {
              "s": "success",
              "t": " 1 done"
            }
          ],
          "tone": "info",
          "took": 10002
        }
      }
    ],
    "id": "main",
    "k": "col",
    "more": 4
  },
  "more": 51,
  "surface": {
    "id": "s:1",
    "mode": "inline",
    "role": "omp.session",
    "title": "omp"
  }
}
]==]
