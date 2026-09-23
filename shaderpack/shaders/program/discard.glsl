// Geometry this pack replaces or does not draw (vanilla clouds, armor glint for now).
#ifdef VERTEX
void main() { gl_Position = vec4(10.0, 10.0, 10.0, 1.0); }
#endif
#ifdef FRAGMENT
void main() { discard; }
#endif
