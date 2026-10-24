# System-wide Jupyter server settings for people's notebook containers (installed as /etc/jupyter/jupyter_server_config.py).
#
# JupyterHub's single-user server answers every page with `Content-Security-Policy: frame-ancestors 'none'`, which forbids showing any of
# its pages inside a frame. JupyterLab's Voilà preview panel is exactly that: it shows /voila/render/<notebook> in an iframe next to the
# notebook, so with the default the panel stays blank (the browser refuses to display the page and Voilà's scripts never load).
# 'self' allows framing by pages of the same origin only (JupyterLab itself); other websites still cannot frame these pages.
# JupyterHub applies its default with setdefault(), so a value set here is kept.
c = get_config()  # noqa: F821  (provided by Jupyter)
c.ServerApp.tornado_settings = {"headers": {"Content-Security-Policy": "frame-ancestors 'self'"}}
