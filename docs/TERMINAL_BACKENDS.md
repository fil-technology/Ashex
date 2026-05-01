# Terminal Backends

The current terminal backend is local process execution.

The config shape anticipated by the prompt is:

```toml
[terminal]
backend = "local"
approval_required = true
docker_forward_env = []
```

Docker, SSH, singularity, and cloud sandbox hooks are not active yet. They should implement the same execution policy, redaction, audit, and approval behavior as the local backend.

