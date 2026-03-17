FROM carlasim/carla:0.9.15

USER carla
WORKDIR /home/carla

# The CARLA directory will be mounted at /home/carla/carla at runtime.
CMD ["bash", "carla/CarlaUE4.sh", "-RenderOffScreen", "-nosound", "-carla-rpc-port=2000", "-graphicsadapter=0"]
