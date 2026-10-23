/* Pixel-space CA coordinates, premultiplied vertex tint, and the five
 * columns delivered by GLContext::function_uniform(index0,4,5,values).
 * Shared with the software-Mesa shader pixel test. */
static const char ca_vertex_source[] =
    "attribute highp vec4 p; attribute lowp vec4 c; attribute highp vec2 t;"
    "uniform highp mat4 mvp; uniform highp vec2 invSize;"
    "varying lowp vec4 tint; varying highp vec2 uv;"
    "void main(){gl_Position=mvp*p;tint=c;uv=t*invSize;}";
static const char ca_copy_source[] =
    "precision mediump float; varying lowp vec4 tint; varying highp vec2 uv;"
    "uniform sampler2D src;void main(){gl_FragColor=texture2D(src,uv)*tint;}";
static const char ca_color_source[] =
    "precision mediump float; varying lowp vec4 tint; varying highp vec2 uv;"
    "uniform sampler2D src; uniform mediump vec4 cols[5];"
    "void main(){vec4 s=texture2D(src,uv)*tint;"
    "gl_FragColor=clamp(s.r*cols[0]+s.g*cols[1]+s.b*cols[2]+s.a*cols[3]+cols[4],0.,1.);}";
