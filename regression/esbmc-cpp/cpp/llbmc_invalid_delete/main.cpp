class Base1
{
public:
    virtual int f(void) { return 21; }
};

class Base2
{
public:
    virtual int g(void) { return 21; }
};

class Derived: public Base1, public Base2
{
public:
    virtual int f(void) { return 42; }
    virtual int g(void) { return 42; }
};

int main()
{
    Base2 *o = new Derived();
    int r = o->g();
    delete o;
    return r;
}

